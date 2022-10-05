// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {Clones} from "openzeppelin/proxy/Clones.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IERC1155} from "openzeppelin/token/ERC1155/IERC1155.sol";
import {ECDSA} from "openzeppelin/utils/cryptography/ECDSA.sol";

import {Vault} from "./Vault.sol";
import {IRoyaltyEngine} from "./interfaces/IRoyaltyEngine.sol";

contract Forward is Ownable {
    using Clones for address;
    using SafeERC20 for IERC20;

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
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

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
            0x0385603ab55642cb4Dd5De3aE9e306809991804f
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
        uint128 fillAmount = details.fillAmount;

        // Ensure the bid is not expired
        if (bid.expiration <= block.timestamp) {
            revert ExpiredBid();
        }

        // Ensure the maker's signature is valid
        bytes32 eip712Hash = _getEIP712Hash(getBidHash(bid));
        // TODO: Add support for EIP2098 and EIP1271 signatures
        address signer = ECDSA.recover(eip712Hash, details.signature);
        if (signer != maker) {
            revert InvalidSignature();
        }

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
            address(bid.token),
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
            IERC721(bid.token).safeTransferFrom(
                msg.sender,
                address(vault),
                identifier
            );

            vault.lockERC721(
                IERC721(bid.token),
                identifier,
                totalRoyaltyAmount
            );
        } else {
            // Ensure ERC1155 bids have a fill amount of at least "1"
            if (fillAmount < 1) {
                revert InvalidFillAmount();
            }

            // Lock the NFT in the maker's vault
            IERC1155(bid.token).safeTransferFrom(
                msg.sender,
                address(vault),
                identifier,
                fillAmount,
                ""
            );

            vault.lockERC1155(
                IERC1155(bid.token),
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
            bid.token,
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
}
