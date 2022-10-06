// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {Clones} from "openzeppelin/proxy/Clones.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IERC1155} from "openzeppelin/token/ERC1155/IERC1155.sol";

import {Vault} from "./Vault.sol";
import {IRoyaltyEngine} from "./interfaces/IRoyaltyEngine.sol";

contract Forward is Ownable {
    using Clones for address;

    // Structs and enums

    enum ItemKind {
        ERC721,
        ERC1155,
        ERC721_WITH_CRITERIA,
        ERC1155_WITH_CRITERIA
    }

    struct Bid {
        ItemKind itemKind;
        address maker;
        address token;
        uint256 identifierOrCriteria;
        uint256 unitPrice;
        uint128 amount;
        uint128 salt;
        uint256 expiration;
    }

    struct BidStatus {
        bool cancelled;
        uint128 filledAmount;
    }

    struct FillDetails {
        Bid bid;
        bytes signature;
        uint128 fillAmount;
    }

    // Errors

    error CancelledBid();
    error ExpiredBid();
    error InvalidBid();

    error InsufficientAmountAvailable();
    error InvalidCriteriaProof();
    error InvalidFillAmount();
    error InvalidMinDiffBps();
    error InvalidSignature();

    error ExistingVault();
    error MissingVault();

    error Unauthorized();

    // Events

    event VaultCreated(address owner, address vault);

    event MinDiffBpsUpdated(uint256 newMinDiffBps);
    event RoyaltyEngineUpdated(address newRoyaltyEngine);

    event BidCancelled(bytes32 bidHash);
    event BidFilled(
        bytes32 bidHash,
        address maker,
        address taker,
        address token,
        uint256 identifier,
        uint256 unitPrice,
        uint128 amount
    );

    event CounterIncremented(address maker, uint256 newCounter);

    // Public constants

    IERC20 public constant WETH =
        IERC20(0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6);

    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public immutable BID_TYPEHASH;

    // Public fields

    // Implementation contract for EIP1167 user vault proxies
    Vault public immutable vaultImplementation;

    // The royalties of all listings from the user vaults must be
    // within `minDiffBps` of the bid royalties, otherwise it can
    // be possible to evade paying the royalties by using private
    // listings with a zero (or very low) price.
    uint256 public minDiffBps;

    // The royalty engine compatible contract used for royalty lookups
    IRoyaltyEngine public royaltyEngine;

    mapping(bytes32 => BidStatus) public bidStatuses;
    mapping(address => uint256) public counters;
    mapping(address => Vault) public vaults;

    // Constructor

    constructor() {
        // Deploy the implementation contract all vault proxies will point to
        vaultImplementation = new Vault();

        // Initially set to 50%
        minDiffBps = 5000;

        // Use the default royalty engine
        royaltyEngine = IRoyaltyEngine(
            0xe7c9Cb6D966f76f3B5142167088927Bf34966a1f
        );

        uint256 chainId;
        assembly {
            chainId := chainid()
        }

        // TODO: Pre-compute and store as a constant
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain("
                    "string name,"
                    "string version,"
                    "uint256 chainId,"
                    "address verifyingContract"
                    ")"
                ),
                keccak256("Forward"),
                keccak256("1.0"),
                chainId,
                address(this)
            )
        );

        // TODO: Pre-compute and store as a constant
        BID_TYPEHASH = keccak256(
            abi.encodePacked(
                "Bid(",
                "uint8 itemKind,",
                "address maker,",
                "address token,",
                "uint256 identifierOrCriteria,",
                "uint256 unitPrice,",
                "uint128 amount,",
                "uint128 salt,",
                "uint256 expiration,",
                "uint256 counter",
                ")"
            )
        );
    }

    // Restricted methods

    function updateRoyaltyEngine(address newRoyaltyEngine) external onlyOwner {
        royaltyEngine = IRoyaltyEngine(newRoyaltyEngine);
        emit RoyaltyEngineUpdated(newRoyaltyEngine);
    }

    function updateMinDiffBps(uint256 newMinDiffBps) external onlyOwner {
        // Ensure the new value is a valid bps
        if (newMinDiffBps > 10000) {
            revert InvalidMinDiffBps();
        }

        minDiffBps = newMinDiffBps;
        emit MinDiffBpsUpdated(newMinDiffBps);
    }

    // Public methods

    function createVault(bytes32 seaportConduitKey)
        external
        returns (Vault vault)
    {
        // Ensure the sender has no vault
        vault = vaults[msg.sender];
        if (address(vault) != address(0)) {
            revert ExistingVault();
        }

        // Deploy and initialize the vault using EIP1167
        vault = Vault(
            payable(
                address(vaultImplementation).cloneDeterministic(
                    keccak256(abi.encodePacked(msg.sender))
                )
            )
        );
        vault.initialize(address(this), msg.sender, seaportConduitKey);

        // Associate the vault to the sender
        vaults[msg.sender] = vault;

        emit VaultCreated(msg.sender, address(vault));
    }

    function fill(FillDetails calldata details) external {
        // Ensure the bid is non-criteria-based
        ItemKind itemKind = details.bid.itemKind;
        if (itemKind != ItemKind.ERC721 && itemKind != ItemKind.ERC1155) {
            revert InvalidBid();
        }

        _fill(details, details.bid.identifierOrCriteria);
    }

    function fillWithCriteria(
        FillDetails calldata details,
        uint256 identifier,
        bytes32[] calldata criteriaProof
    ) external {
        // Ensure the bid is criteria-based
        ItemKind itemKind = details.bid.itemKind;
        if (
            itemKind != ItemKind.ERC721_WITH_CRITERIA &&
            itemKind != ItemKind.ERC1155_WITH_CRITERIA
        ) {
            revert InvalidBid();
        }

        // Ensure the provided identifier matches the bid's criteria
        if (details.bid.identifierOrCriteria != 0) {
            // The zero criteria will match any identifier
            _verifyCriteriaProof(
                identifier,
                details.bid.identifierOrCriteria,
                criteriaProof
            );
        }

        _fill(details, identifier);
    }

    function cancel(Bid[] calldata bids) external {
        uint256 length = bids.length;
        for (uint256 i = 0; i < length; ) {
            Bid memory bid = bids[i];

            // Only the bid's maker can cancel
            if (bid.maker != msg.sender) {
                revert Unauthorized();
            }

            // Mark the bid as cancelled
            bytes32 bidHash = getBidHash(bid);
            bidStatuses[bidHash].cancelled = true;

            unchecked {
                ++i;
            }
        }
    }

    function incrementCounter() external {
        // Similar to Seaport's implementation, incrementing the counter
        // will cancel any orders which were signed with a counter value
        // which is a lower than the updated value.
        uint256 newCounter;
        unchecked {
            newCounter = ++counters[msg.sender];
        }

        emit CounterIncremented(msg.sender, newCounter);
    }

    function getBidHash(Bid memory bid) public view returns (bytes32 bidHash) {
        // TODO: Optimize by using assembly
        bidHash = keccak256(
            abi.encode(
                BID_TYPEHASH,
                bid.itemKind,
                bid.maker,
                bid.token,
                bid.identifierOrCriteria,
                bid.unitPrice,
                bid.amount,
                bid.salt,
                bid.expiration,
                counters[bid.maker]
            )
        );
    }

    // Internal methods

    function _fill(FillDetails memory details, uint256 identifier) internal {
        // Cache some data for gas-efficiency
        Bid memory bid = details.bid;

        address maker = bid.maker;
        address token = bid.token;
        uint128 fillAmount = details.fillAmount;

        // Ensure the bid is not expired
        if (bid.expiration <= block.timestamp) {
            revert ExpiredBid();
        }

        // Ensure the maker's signature is valid
        bytes32 eip712Hash = _getEIP712Hash(getBidHash(bid));
        _verifySignature(maker, eip712Hash, details.signature);

        BidStatus memory bidStatus = bidStatuses[eip712Hash];
        // Ensure the bid is not cancelled
        if (bidStatus.cancelled) {
            revert CancelledBid();
        }
        // Ensure the amount to fill is available
        if (bid.amount - bidStatus.filledAmount < fillAmount) {
            revert InsufficientAmountAvailable();
        }

        // Ensure the maker has initialized a vault
        Vault vault = vaults[maker];
        if (address(vault) == address(0)) {
            revert MissingVault();
        }

        uint256 totalPrice = bid.unitPrice * fillAmount;

        // Fetch the item's royalties
        (, uint256[] memory royaltyAmounts) = royaltyEngine.getRoyaltyView(
            token,
            identifier,
            totalPrice
        );

        // Compute the total royalty amount
        uint256 totalRoyaltyAmount;
        uint256 royaltiesLength = royaltyAmounts.length;
        for (uint256 i = 0; i < royaltiesLength; ) {
            totalRoyaltyAmount += royaltyAmounts[i];

            unchecked {
                ++i;
            }
        }

        // Send the payment to the taker
        WETH.transferFrom(maker, msg.sender, totalPrice - totalRoyaltyAmount);

        // Lock the royalty in the maker's vault
        WETH.transferFrom(maker, address(vault), totalRoyaltyAmount);

        if (
            bid.itemKind == ItemKind.ERC721 ||
            bid.itemKind == ItemKind.ERC721_WITH_CRITERIA
        ) {
            // Ensure ERC721 bids have a fill amount of "1"
            if (fillAmount != 1) {
                revert InvalidFillAmount();
            }

            // Lock the NFT in the maker's vault
            IERC721(token).safeTransferFrom(
                msg.sender,
                address(vault),
                identifier
            );

            vault.lockERC721(IERC721(token), identifier, totalRoyaltyAmount);
        } else {
            // Ensure ERC1155 bids have a fill amount of at least "1"
            if (fillAmount < 1) {
                revert InvalidFillAmount();
            }

            // Lock the NFT in the maker's vault
            IERC1155(token).safeTransferFrom(
                msg.sender,
                address(vault),
                identifier,
                fillAmount,
                ""
            );

            vault.lockERC1155(
                IERC1155(token),
                identifier,
                fillAmount,
                totalRoyaltyAmount
            );
        }

        // Update the bid's filled amount
        bidStatuses[eip712Hash].filledAmount += fillAmount;

        emit BidFilled(
            eip712Hash,
            maker,
            msg.sender,
            token,
            identifier,
            bid.unitPrice,
            fillAmount
        );
    }

    function _getEIP712Hash(bytes32 structHash)
        internal
        view
        returns (bytes32 eip712Hash)
    {
        eip712Hash = keccak256(
            abi.encodePacked(hex"1901", DOMAIN_SEPARATOR, structHash)
        );
    }

    // Taken from:
    // https://github.com/ProjectOpenSea/seaport/blob/dfce06d02413636f324f73352b54a4497d63c310/contracts/lib/CriteriaResolution.sol#L243-L247
    function _verifyCriteriaProof(
        uint256 leaf,
        uint256 root,
        bytes32[] memory criteriaProof
    ) internal pure {
        bool isValid;

        assembly {
            // Store the leaf at the beginning of scratch space
            mstore(0, leaf)

            // Derive the hash of the leaf to use as the initial proof element
            let computedHash := keccak256(0, 0x20)
            // Get memory start location of the first element in proof array
            let data := add(criteriaProof, 0x20)

            for {
                // Left shift by 5 is equivalent to multiplying by 0x20
                let end := add(data, shl(5, mload(criteriaProof)))
            } lt(data, end) {
                // Increment by one word at a time
                data := add(data, 0x20)
            } {
                // Get the proof element
                let loadedData := mload(data)

                // Sort proof elements and place them in scratch space
                let scratch := shl(5, gt(computedHash, loadedData))
                mstore(scratch, computedHash)
                mstore(xor(scratch, 0x20), loadedData)

                // Derive the updated hash
                computedHash := keccak256(0, 0x40)
            }

            isValid := eq(computedHash, root)
        }

        if (!isValid) {
            revert InvalidCriteriaProof();
        }
    }

    // Taken from:
    // https://github.com/ProjectOpenSea/seaport/blob/e4c6e7b294d7b564fe3fe50c1f786cae9c8ec575/contracts/lib/SignatureVerification.sol#L31-L35
    function _verifySignature(
        address signer,
        bytes32 digest,
        bytes memory signature
    ) internal view {
        bool success;

        // TODO: Add support for EIP1271 contract signatures
        assembly {
            // Ensure that first word of scratch space is empty
            mstore(0, 0)

            let v
            let signatureLength := mload(signature)

            // Get the pointer to the value preceding the signature length
            let wordBeforeSignaturePtr := sub(signature, 0x20)

            // Cache the current value behind the signature to restore it later
            let cachedWordBeforeSignature := mload(wordBeforeSignaturePtr)

            // Declare lenDiff + recoveredSigner scope to manage stack pressure
            {
                // Take the difference between the max ECDSA signature length and the actual signature length
                // Overflow desired for any values > 65
                // If the diff is not 0 or 1, it is not a valid ECDSA signature
                let lenDiff := sub(65, signatureLength)

                let recoveredSigner

                // If diff is 0 or 1, it may be an ECDSA signature, so try to recover signer
                if iszero(gt(lenDiff, 1)) {
                    // Read the signature `s` value
                    let originalSignatureS := mload(add(signature, 0x40))

                    // Read the first byte of the word after `s`
                    // If the signature is 65 bytes, this will be the real `v` value
                    // If not, it will need to be modified - doing it this way saves an extra condition
                    v := byte(0, mload(add(signature, 0x60)))

                    // If lenDiff is 1, parse 64-byte signature as ECDSA
                    if lenDiff {
                        // Extract yParity from highest bit of vs and add 27 to get v
                        v := add(shr(0xff, originalSignatureS), 27)

                        // Extract canonical s from vs, all but the highest bit
                        // Temporarily overwrite the original `s` value in the signature
                        mstore(
                            add(signature, 0x40),
                            and(
                                originalSignatureS,
                                0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
                            )
                        )
                    }

                    // Temporarily overwrite the signature length with `v` to conform to the expected input for ecrecover
                    mstore(signature, v)

                    // Temporarily overwrite the word before the length with `digest` to conform to the expected input for ecrecover
                    mstore(wordBeforeSignaturePtr, digest)

                    // Attempt to recover the signer for the given signature
                    // Do not check the call status as ecrecover will return a null address if the signature is invalid
                    pop(
                        staticcall(
                            gas(),
                            1, // Call ecrecover precompile
                            wordBeforeSignaturePtr, // Use data memory location
                            0x80, // Size of digest, v, r, and s
                            0, // Write result to scratch space
                            0x20 // Provide size of returned result
                        )
                    )

                    // Restore cached word before signature
                    mstore(wordBeforeSignaturePtr, cachedWordBeforeSignature)

                    // Restore cached signature length
                    mstore(signature, signatureLength)

                    // Restore cached signature `s` value
                    mstore(add(signature, 0x40), originalSignatureS)

                    // Read the recovered signer from the buffer given as return space for ecrecover
                    recoveredSigner := mload(0)
                }

                // Set success to true if the signature provided was a valid ECDSA signature and the signer is not the null address
                // Use gt instead of direct as success is used outside of assembly
                success := and(eq(signer, recoveredSigner), gt(signer, 0))
            }
        }

        if (!success) {
            revert InvalidSignature();
        }
    }
}
