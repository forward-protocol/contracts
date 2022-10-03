// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Clones} from "openzeppelin/proxy/Clones.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IERC1155} from "openzeppelin/token/ERC1155/IERC1155.sol";
import {ECDSA} from "openzeppelin/utils/cryptography/ECDSA.sol";

import {Vault} from "./Vault.sol";
import {IRoyaltyEngine} from "./interfaces/IRoyaltyEngine.sol";

contract Forward {
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
        uint256 price;
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
    error InvalidFillAmount();

    error InvalidCriteriaProof();
    error InvalidSignature();

    error ExistingVault();
    error MissingVault();

    error Unauthorized();

    // Events

    event VaultCreated(address owner, address vault);

    event BidCancelled(bytes32 bidHash);
    event BidFilled(
        address maker,
        address taker,
        address token,
        uint256 identifier,
        uint256 price,
        uint128 amount
    );
    event CounterIncremented(uint256 newCounter, address maker);

    // Public constants

    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    IRoyaltyEngine public constant ROYALTY_ENGINE =
        IRoyaltyEngine(0x0385603ab55642cb4Dd5De3aE9e306809991804f);

    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public immutable BID_TYPEHASH;

    Vault private immutable vaultImplementation;

    // Public fields

    mapping(bytes32 => BidStatus) public bidStatuses;
    mapping(address => uint256) public counters;
    mapping(address => Vault) public vaults;

    // Constructor

    constructor() {
        vaultImplementation = new Vault();

        uint256 chainId;
        assembly {
            chainId := chainid()
        }

        // TODO: Precompute and store as a constant
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

        // TODO: Precompute and store as a constant
        BID_TYPEHASH = keccak256(
            abi.encodePacked(
                "Bid(",
                "uint8 itemKind,",
                "address maker,",
                "address token,",
                "uint256 identifierOrCriteria,",
                "uint256 price,",
                "uint128 amount,",
                "uint128 salt,",
                "uint256 expiration,",
                "uint256 counter",
                ")"
            )
        );
    }

    // Public methods

    function createVault() external returns (Vault vault) {
        // Ensure the sender has no vault
        vault = vaults[msg.sender];
        if (address(vault) != address(0)) {
            revert ExistingVault();
        }

        // Deploy and initialize the vault
        vault = Vault(
            payable(
                address(vaultImplementation).cloneDeterministic(
                    keccak256(abi.encodePacked(msg.sender))
                )
            )
        );
        vault.initialize(address(this), msg.sender);

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
            // Only the bid's maker can cancel
            if (bids[i].maker != msg.sender) {
                revert Unauthorized();
            }

            // Mark the bid as cancelled
            bytes32 bidHash = getBidHash(bids[i]);
            bidStatuses[bidHash].cancelled = true;

            unchecked {
                ++i;
            }
        }
    }

    function incrementCounter() external {
        uint256 newCounter;
        unchecked {
            newCounter = ++counters[msg.sender];
        }

        emit CounterIncremented(newCounter, msg.sender);
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
                bid.price,
                bid.amount,
                bid.salt,
                bid.expiration,
                counters[bid.maker]
            )
        );
    }

    // Internal methods

    function _fill(FillDetails memory details, uint256 identifier) internal {
        // Ensure the bid is not expired
        if (details.bid.expiration <= block.timestamp) {
            revert ExpiredBid();
        }

        // Ensure the maker's signature is valid
        bytes32 eip712Hash = _getEIP712Hash(getBidHash(details.bid));
        // TODO: Add support for EIP2098 and EIP1271 signatures
        address signer = ECDSA.recover(eip712Hash, details.signature);
        if (signer != details.bid.maker) {
            revert InvalidSignature();
        }

        BidStatus memory bidStatus = bidStatuses[eip712Hash];
        // Ensure the bid is not cancelled
        if (bidStatus.cancelled) {
            revert CancelledBid();
        }
        // Ensure the amount to fill is available
        if (details.bid.amount - bidStatus.filledAmount < details.fillAmount) {
            revert InsufficientAmountAvailable();
        }

        // Ensure the maker has initialized a vault
        Vault vault = vaults[details.bid.maker];
        if (address(vault) == address(0)) {
            revert MissingVault();
        }

        // Fetch the item's royalties
        (, uint256[] memory royaltyAmounts) = ROYALTY_ENGINE.getRoyaltyView(
            address(details.bid.token),
            identifier,
            details.bid.price
        );

        // Compute the total royalty amount
        uint256 totalRoyaltyAmount;
        uint256 royaltiesLength = royaltyAmounts.length;
        for (uint256 i = 0; i < royaltiesLength; ) {
            totalRoyaltyAmount += royaltyAmounts[i] * details.fillAmount;

            unchecked {
                ++i;
            }
        }

        // Send the payment to the taker
        WETH.transferFrom(
            details.bid.maker,
            msg.sender,
            details.bid.price - totalRoyaltyAmount
        );

        // Lock the royalty in the maker's vault
        WETH.transferFrom(
            details.bid.maker,
            address(vault),
            totalRoyaltyAmount
        );

        if (
            details.bid.itemKind == ItemKind.ERC721 ||
            details.bid.itemKind == ItemKind.ERC721_WITH_CRITERIA
        ) {
            // Ensure ERC721 bids have a fill amount of "1"
            if (details.fillAmount != 1) {
                revert InvalidFillAmount();
            }

            // Lock the NFT in the maker's vault
            IERC721(details.bid.token).safeTransferFrom(
                msg.sender,
                address(vault),
                identifier
            );

            vault.lockERC721(
                IERC721(details.bid.token),
                identifier,
                totalRoyaltyAmount
            );
        } else {
            // Lock the NFT in the maker's vault
            IERC1155(details.bid.token).safeTransferFrom(
                msg.sender,
                address(vault),
                identifier,
                details.fillAmount,
                ""
            );

            vault.lockERC1155(
                IERC1155(details.bid.token),
                identifier,
                details.fillAmount,
                totalRoyaltyAmount
            );
        }

        // Update the bid's filled amount
        bidStatuses[eip712Hash].filledAmount += details.fillAmount;

        emit BidFilled(
            details.bid.maker,
            msg.sender,
            details.bid.token,
            identifier,
            details.bid.price,
            details.fillAmount
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
