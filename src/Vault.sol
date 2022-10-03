// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IERC1155} from "openzeppelin/token/ERC1155/IERC1155.sol";
import {ECDSA} from "openzeppelin/utils/cryptography/ECDSA.sol";

import {IRoyaltyEngine} from "./interfaces/IRoyaltyEngine.sol";
import {ISeaport} from "./interfaces/ISeaport.sol";

// TODO: Allow cancelling and/or bulk cancelling

contract Vault {
    using SafeERC20 for IERC20;

    // Structs

    struct Payment {
        uint256 amount;
        address recipient;
    }

    struct SeaportListingDetails {
        ISeaport.ItemType itemType;
        address token;
        uint256 identifier;
        uint256 amount;
        uint256 startTime;
        uint256 endTime;
        uint256 salt;
        Payment[] payments;
    }

    struct ERC721Lock {
        uint256 royalty;
    }

    struct ERC1155Lock {
        uint256 royalty;
        uint256 amount;
    }

    // Errors

    error AlreadyInitialized();

    error InvalidListing();

    error Unauthorized();
    error UnsuccessfulCall();

    // Public constants

    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    ISeaport public constant SEAPORT =
        ISeaport(0x00000000006c3852cbEf3e08E8dF289169EdE581);

    // TODO: Retrieve this from the core `Forward` contract (in order to be able to override)
    IRoyaltyEngine public constant ROYALTY_ENGINE =
        IRoyaltyEngine(0x0385603ab55642cb4Dd5De3aE9e306809991804f);

    // TODO: Allow the owner to dynamically change these
    bytes32 public constant SEAPORT_OPENSEA_CONDUIT_KEY =
        0x0000007b02230091a7ed01230072f7006a004d60a8d4e71d599b8104250f0000;
    address public constant SEAPORT_OPENSEA_CONDUIT =
        0x1E0049783F008A0085193E00003D00cd54003c71;

    bytes32 public SEAPORT_DOMAIN_SEPARATOR;

    // Public fields

    address public exchange;
    address public owner;

    // Private fields

    mapping(bytes32 => ERC721Lock) public erc721Locks;
    mapping(bytes32 => ERC1155Lock) public erc1155Locks;

    // Constructor

    function initialize(address _exchange, address _owner) public {
        if (exchange != address(0)) {
            revert AlreadyInitialized();
        }

        exchange = _exchange;
        owner = _owner;

        // Cache the Seaport EIP712 domain separator
        (, SEAPORT_DOMAIN_SEPARATOR, ) = SEAPORT.information();
    }

    // Receive fallback

    receive() external payable {
        (bool success, ) = payable(owner).call{value: msg.value}("");
        if (!success) {
            revert UnsuccessfulCall();
        }
    }

    // Permissioned methods

    function lockERC721(
        IERC721 token,
        uint256 identifier,
        uint256 royalty
    ) external {
        // Only the deployer can lock tokens
        if (msg.sender != exchange) {
            revert Unauthorized();
        }

        // Fetch the item's lock
        bytes32 itemHash = keccak256(abi.encode(token, identifier));

        // Automatically unlock if there is a pending lock
        if (erc721Locks[itemHash].royalty > 0) {
            unlockERC721(token, identifier);
        }

        // Keep track of the locked royalty
        erc721Locks[itemHash].royalty = royalty;

        // Approve the conduit for listing
        bool isApproved = token.isApprovedForAll(
            address(this),
            SEAPORT_OPENSEA_CONDUIT
        );
        if (!isApproved) {
            token.setApprovalForAll(SEAPORT_OPENSEA_CONDUIT, true);
        }
    }

    function lockERC1155(
        IERC1155 token,
        uint256 identifier,
        uint256 amount,
        uint256 royalty
    ) external {
        // Only the deployer can lock tokens
        if (msg.sender != exchange) {
            revert Unauthorized();
        }

        // Fetch the item's lock
        bytes32 itemHash = keccak256(abi.encode(token, identifier));

        // Keep track of the locked royalty
        erc1155Locks[itemHash].royalty += royalty;
        erc1155Locks[itemHash].amount += amount;

        // Approve the conduit for listing
        bool isApproved = token.isApprovedForAll(
            address(this),
            SEAPORT_OPENSEA_CONDUIT
        );
        if (!isApproved) {
            token.setApprovalForAll(SEAPORT_OPENSEA_CONDUIT, true);
        }
    }

    function unlockERC721(IERC721 token, uint256 identifier) public {
        address tokenOwner = token.ownerOf(identifier);
        if (tokenOwner == address(this)) {
            if (msg.sender != owner) {
                // If the unlock results in losing locked royalties,
                // then ensure only the owner is authorized to do it
                revert Unauthorized();
            }

            token.safeTransferFrom(address(this), owner, identifier);
        }

        // Fetch the item's lock
        bytes32 itemHash = keccak256(abi.encode(token, identifier));
        uint256 lockedRoyalty = erc721Locks[itemHash].royalty;
        if (lockedRoyalty > 0) {
            // Fetch the royalty distribution
            (
                address[] memory royaltyRecipients,
                uint256[] memory royaltyAmounts
            ) = ROYALTY_ENGINE.getRoyaltyView(
                    address(token),
                    identifier,
                    lockedRoyalty
                );

            uint256 i;

            // Compute the total royalty
            uint256 totalRoyaltyAmount;
            uint256 royaltiesLength = royaltyAmounts.length;
            for (i = 0; i < royaltiesLength; ) {
                totalRoyaltyAmount += royaltyAmounts[i];

                unchecked {
                    ++i;
                }
            }

            for (i = 0; i < royaltiesLength; ) {
                WETH.safeTransfer(
                    // If the vault is still the owner of the item then we pay the
                    // royalties. Otherwise, we assume the item was sold through a
                    // Seaport listing (enforced to be paying out royalties) so we
                    // refund the locked royalties to the vault owner.
                    tokenOwner == address(this) ? royaltyRecipients[i] : owner,
                    (lockedRoyalty * royaltyAmounts[i]) / totalRoyaltyAmount
                );

                unchecked {
                    ++i;
                }
            }

            // Clear the item's lock
            erc721Locks[itemHash].royalty = 0;
        }
    }

    function unlockERC1155(
        IERC1155 token,
        uint256 identifier,
        uint256 amount
    ) public {
        bytes32 itemHash = keccak256(abi.encode(token, identifier));
        ERC1155Lock memory lock = erc1155Locks[itemHash];

        // Fetch the vault's token balance
        uint256 tokenBalance = token.balanceOf(address(this), identifier);

        // Any locked amount greater than the vault's balance is assumed to have been unlocked
        uint256 unlockedAmount = lock.amount >= tokenBalance
            ? lock.amount - tokenBalance
            : 0;

        uint256 amountWithLockedRoyalties;
        uint256 amountWithUnlockedRoyalties;
        if (amount > unlockedAmount) {
            amountWithLockedRoyalties = amount - unlockedAmount;
            amountWithUnlockedRoyalties = unlockedAmount;
        } else {
            amountWithUnlockedRoyalties = amount;
        }

        if (amountWithLockedRoyalties > 0) {
            if (msg.sender != owner) {
                // If the unlock results in losing locked royalties,
                // then ensure only the owner is authorized to do it
                revert Unauthorized();
            }

            token.safeTransferFrom(
                address(this),
                owner,
                identifier,
                amountWithLockedRoyalties,
                ""
            );
        }

        if (amount > 0) {
            // Fetch the item's royalties
            (
                address[] memory royaltyRecipients,
                uint256[] memory royaltyAmounts
            ) = ROYALTY_ENGINE.getRoyaltyView(
                    address(token),
                    identifier,
                    (lock.royalty * amount) / lock.amount
                );

            uint256 i;

            // Compute the total royalty amount
            uint256 totalRoyaltyAmount;
            uint256 royaltiesLength = royaltyAmounts.length;
            for (i = 0; i < royaltiesLength; ) {
                totalRoyaltyAmount += royaltyAmounts[i];

                unchecked {
                    ++i;
                }
            }

            uint256 royaltyPayout;
            for (i = 0; i < royaltiesLength; ) {
                uint256 payout;

                if (amountWithLockedRoyalties > 0) {
                    payout =
                        (lock.royalty *
                            amountWithLockedRoyalties *
                            royaltyAmounts[i]) /
                        amount /
                        totalRoyaltyAmount;
                    royaltyPayout += payout;

                    WETH.safeTransfer(royaltyRecipients[i], payout);
                }

                if (amountWithUnlockedRoyalties > 0) {
                    payout =
                        (lock.royalty *
                            amountWithUnlockedRoyalties *
                            royaltyAmounts[i]) /
                        amount /
                        totalRoyaltyAmount;
                    royaltyPayout += payout;

                    WETH.safeTransfer(owner, payout);
                }

                unchecked {
                    ++i;
                }
            }

            // Reduce the item's locked amount
            erc1155Locks[itemHash].royalty -= royaltyPayout;
            erc1155Locks[itemHash].amount -= amount;
        }
    }

    // ERC1271

    function isValidSignature(bytes32 digest, bytes memory signature)
        external
        view
        returns (bytes4)
    {
        // Ensure any Seaport order originating from this vault is a listing
        // in the native token which is paying out the correct royalties (as
        // specified via the royalty registry)

        (
            SeaportListingDetails memory listingDetails,
            bytes memory orderSignature
        ) = abi.decode(signature, (SeaportListingDetails, bytes));

        // Ensure the listed item's type is ERC721 or ERC1155
        if (uint8(listingDetails.itemType) < 2) {
            revert InvalidListing();
        }

        // The listing should have a single offer item
        ISeaport.OfferItem[] memory offer = new ISeaport.OfferItem[](1);
        offer[0] = ISeaport.OfferItem({
            itemType: listingDetails.itemType,
            token: listingDetails.token,
            identifierOrCriteria: listingDetails.identifier,
            startAmount: 1,
            endAmount: 1
        });

        // Keep track of the total payment amount
        uint256 totalPrice;

        // Cache the listing's payments for efficiency
        Payment[] memory payments = listingDetails.payments;
        uint256 paymentsLength = payments.length;

        // Construct the consideration items
        ISeaport.ConsiderationItem[]
            memory consideration = new ISeaport.ConsiderationItem[](
                paymentsLength
            );
        {
            for (uint256 i = 0; i < paymentsLength; ) {
                uint256 amount = payments[i].amount;
                totalPrice += amount;

                consideration[i] = ISeaport.ConsiderationItem({
                    itemType: ISeaport.ItemType.NATIVE,
                    token: address(0),
                    identifierOrCriteria: 0,
                    startAmount: amount,
                    endAmount: amount,
                    recipient: payments[i].recipient
                });

                unchecked {
                    ++i;
                }
            }
        }

        {
            // Fetch the item's royalties
            (
                address[] memory royaltyRecipients,
                uint256[] memory royaltyAmounts
            ) = ROYALTY_ENGINE.getRoyaltyView(
                    listingDetails.token,
                    listingDetails.identifier,
                    totalPrice
                );

            // Ensure the royalties are present in the payment items
            uint256 diff = paymentsLength - royaltyAmounts.length;
            for (uint256 i = diff; i < paymentsLength; ) {
                if (
                    payments[i].recipient != royaltyRecipients[i - diff] ||
                    payments[i].amount != royaltyAmounts[i - diff]
                ) {
                    revert InvalidListing();
                }

                unchecked {
                    ++i;
                }
            }
        }

        bytes32 orderHash;
        {
            ISeaport.OrderComponents memory order;
            order.offerer = address(this);
            // order.zone = address(0);
            order.offer = offer;
            order.consideration = consideration;
            order.orderType = ISeaport.OrderType.PARTIAL_OPEN;
            order.startTime = listingDetails.startTime;
            order.endTime = listingDetails.endTime;
            // order.zoneHash = bytes32(0);
            order.salt = listingDetails.salt;
            order.conduitKey = SEAPORT_OPENSEA_CONDUIT_KEY;
            order.counter = SEAPORT.getCounter(address(this));

            orderHash = SEAPORT.getOrderHash(order);
        }
        if (
            digest !=
            keccak256(
                abi.encodePacked(hex"1901", SEAPORT_DOMAIN_SEPARATOR, orderHash)
            )
        ) {
            revert InvalidListing();
        }

        address signer = ECDSA.recover(digest, orderSignature);
        if (signer != owner) {
            revert InvalidListing();
        }

        return this.isValidSignature.selector;
    }

    // ERC721

    function onERC721Received(
        address operator,
        address, // from
        uint256, // tokenId
        bytes calldata // data
    ) external view returns (bytes4) {
        if (operator != exchange) {
            revert Unauthorized();
        }

        return this.onERC721Received.selector;
    }

    // ERC1155

    function onERC1155Received(
        address operator,
        address, // from
        uint256, // id
        uint256, // value
        bytes calldata // data
    ) external view returns (bytes4) {
        if (operator != exchange) {
            revert Unauthorized();
        }

        return this.onERC1155Received.selector;
    }
}
