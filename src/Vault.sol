// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IERC1155} from "openzeppelin/token/ERC1155/IERC1155.sol";
import {ECDSA} from "openzeppelin/utils/cryptography/ECDSA.sol";

import {Forward} from "./Forward.sol";
import {IRoyaltyEngine} from "./interfaces/IRoyaltyEngine.sol";
import {IConduitController, ISeaport} from "./interfaces/ISeaport.sol";

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
    error InexistentSeaportConduit();

    error InvalidListing();

    error Unauthorized();
    error UnsuccessfulCall();

    // Public constants

    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    ISeaport public constant SEAPORT =
        ISeaport(0x00000000006c3852cbEf3e08E8dF289169EdE581);

    IConduitController public constant SEAPORT_CONDUIT_CONTROLLER =
        IConduitController(0x00000000F9490004C11Cef243f5400493c00Ad63);

    bytes32 public constant SEAPORT_DOMAIN_SEPARATOR =
        0xb50c8913581289bd2e066aeef89fceb9615d490d673131fd1a7047436706834e;

    // Public fields

    Forward public forward;
    address public owner;

    bytes32 public seaportConduitKey;
    address public seaportConduit;

    // Private fields

    mapping(bytes32 => ERC721Lock) public erc721Locks;
    mapping(bytes32 => ERC1155Lock) public erc1155Locks;

    // Constructor

    function initialize(
        address _forward,
        address _owner,
        bytes32 _seaportConduitKey
    ) public {
        if (address(forward) != address(0)) {
            revert AlreadyInitialized();
        }

        forward = Forward(_forward);
        owner = _owner;

        // Initialize the conduit
        (address conduit, bool exists) = SEAPORT_CONDUIT_CONTROLLER.getConduit(
            _seaportConduitKey
        );
        if (!exists) {
            revert InexistentSeaportConduit();
        }

        seaportConduitKey = _seaportConduitKey;
        seaportConduit = conduit;
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
        // Only the protocol can lock tokens
        if (msg.sender != address(forward)) {
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
        address conduit = seaportConduit;
        bool isApproved = token.isApprovedForAll(address(this), conduit);
        if (!isApproved) {
            token.setApprovalForAll(conduit, true);
        }
    }

    function lockERC1155(
        IERC1155 token,
        uint256 identifier,
        uint256 amount,
        uint256 royalty
    ) external {
        // Only the protocol can lock tokens
        if (msg.sender != address(forward)) {
            revert Unauthorized();
        }

        // Fetch the item's lock
        bytes32 itemHash = keccak256(abi.encode(token, identifier));

        // Keep track of the locked royalty
        erc1155Locks[itemHash].royalty += royalty;
        erc1155Locks[itemHash].amount += amount;

        // Approve the conduit for listing
        address conduit = seaportConduit;
        bool isApproved = token.isApprovedForAll(address(this), conduit);
        if (!isApproved) {
            token.setApprovalForAll(conduit, true);
        }
    }

    function unlockERC721(IERC721 token, uint256 identifier) public {
        // Cache the vault owner for gas-efficiency
        address vaultOwner = owner;

        address tokenOwner = token.ownerOf(identifier);
        bool itemIsInVault = tokenOwner == address(this);
        if (itemIsInVault) {
            if (msg.sender != vaultOwner) {
                // If the unlock results in losing locked royalties,
                // then ensure only the owner is authorized to do it
                revert Unauthorized();
            }

            // Transfer the token to the vault owner
            token.safeTransferFrom(address(this), vaultOwner, identifier);
        }

        // Fetch the item's locked royalty amount
        bytes32 itemHash = keccak256(abi.encode(token, identifier));
        uint256 lockedRoyalty = erc721Locks[itemHash].royalty;
        if (lockedRoyalty > 0) {
            if (itemIsInVault) {
                // If the vault is still the owner of the item then we pay the royalties

                // Fetch the royalty distribution
                (
                    address[] memory royaltyRecipients,
                    uint256[] memory royaltyAmounts
                ) = forward.royaltyEngine().getRoyaltyView(
                        address(token),
                        identifier,
                        lockedRoyalty
                    );

                uint256 i;

                // Compute the total royalty amount
                uint256 totalRoyalty;
                uint256 royaltiesLength = royaltyAmounts.length;
                for (i = 0; i < royaltiesLength; ) {
                    totalRoyalty += royaltyAmounts[i];

                    unchecked {
                        ++i;
                    }
                }

                for (i = 0; i < royaltiesLength; ) {
                    WETH.safeTransfer(
                        royaltyRecipients[i],
                        // Split the locked royalties pro-rata
                        (lockedRoyalty * royaltyAmounts[i]) / totalRoyalty
                    );

                    unchecked {
                        ++i;
                    }
                }
            } else {
                // Otherwise, we assume the item was sold through a Seaport
                // listing (enforced to be paying out royalties) so we do a
                // refund to the vault owner
                WETH.safeTransfer(owner, lockedRoyalty);
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
        // Cache the vault owner for gas-efficiency
        address vaultOwner = owner;

        // Fetch the item's locked royalty details
        bytes32 itemHash = keccak256(abi.encode(token, identifier));
        ERC1155Lock memory lock = erc1155Locks[itemHash];

        // Fetch the vault's token balance
        uint256 vaultBalance = token.balanceOf(address(this), identifier);

        // Assume any locked amount greater than the vault's balance has been unlocked
        uint256 unlockedAmount = lock.amount >= vaultBalance
            ? lock.amount - vaultBalance
            : 0;

        // Determine how much of the requested unlock amount is locked vs unlocked
        uint256 amountWithLockedRoyalties;
        uint256 amountWithUnlockedRoyalties;
        if (amount > unlockedAmount) {
            amountWithLockedRoyalties = amount - unlockedAmount;
            amountWithUnlockedRoyalties = unlockedAmount;
        } else {
            amountWithUnlockedRoyalties = amount;
        }

        if (amountWithLockedRoyalties > 0) {
            if (msg.sender != vaultOwner) {
                // If the unlock results in losing locked royalties,
                // then ensure only the owner is authorized to do it
                revert Unauthorized();
            }

            // Transfer the locked amount to the vault owner
            token.safeTransferFrom(
                address(this),
                vaultOwner,
                identifier,
                amountWithLockedRoyalties,
                ""
            );
        }

        uint256 totalRoyaltyPayout;
        if (amountWithUnlockedRoyalties > 0) {
            // Royalties corresponding to an unlocked amount get refunded to the vault owner

            uint256 payout = (lock.royalty * amountWithUnlockedRoyalties) /
                lock.amount;
            totalRoyaltyPayout += payout;

            WETH.safeTransfer(vaultOwner, payout);
        }
        if (amountWithLockedRoyalties > 0) {
            // Royalties corresponding to a locked amount get paid

            // Fetch the royalty distribution
            (
                address[] memory royaltyRecipients,
                uint256[] memory royaltyAmounts
            ) = forward.royaltyEngine().getRoyaltyView(
                    address(token),
                    identifier,
                    // The locked royalty is averaged across the amount of locked tokens
                    (lock.royalty * amountWithLockedRoyalties) / lock.amount
                );

            uint256 i;

            // Compute the total royalty amount
            uint256 totalRoyalty;
            uint256 royaltiesLength = royaltyAmounts.length;
            for (i = 0; i < royaltiesLength; ) {
                totalRoyalty += royaltyAmounts[i];

                unchecked {
                    ++i;
                }
            }

            for (i = 0; i < royaltiesLength; ) {
                uint256 payout = (lock.royalty *
                    amountWithLockedRoyalties *
                    royaltyAmounts[i]) /
                    lock.amount /
                    totalRoyalty;
                totalRoyaltyPayout += payout;

                WETH.safeTransfer(royaltyRecipients[i], payout);

                unchecked {
                    ++i;
                }
            }
        }

        if (amount > 0 || totalRoyaltyPayout > 0) {
            // Reduce the item's locked amount
            erc1155Locks[itemHash].royalty -= totalRoyaltyPayout;
            erc1155Locks[itemHash].amount -= amount;
        }
    }

    function cancel(ISeaport.OrderComponents[] calldata orders)
        external
        returns (bool cancelled)
    {
        // Only the owner can cancel orders
        if (msg.sender != owner) {
            revert Unauthorized();
        }

        cancelled = SEAPORT.cancel(orders);
    }

    function incrementCounter() external returns (uint256 newCounter) {
        // Only the owner can increment the counter
        if (msg.sender != owner) {
            revert Unauthorized();
        }

        newCounter = SEAPORT.incrementCounter();
    }

    function updateSeaportConduitKey(bytes32 newSeaportConduitKey) external {
        // Only the owner can update the Seaport conduit key
        if (msg.sender != owner) {
            revert Unauthorized();
        }

        (address conduit, bool exists) = SEAPORT_CONDUIT_CONTROLLER.getConduit(
            newSeaportConduitKey
        );
        if (!exists) {
            revert InexistentSeaportConduit();
        }

        seaportConduitKey = newSeaportConduitKey;
        seaportConduit = conduit;
    }

    // ERC1271

    function isValidSignature(bytes32 digest, bytes memory signature)
        external
        view
        returns (bytes4)
    {
        // Ensure any Seaport order originating from this vault is a listing
        // in the native token which is paying out the correct royalties (as
        // specified via the royalty registry).

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
            startAmount: listingDetails.amount,
            endAmount: listingDetails.amount
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
            uint256 minDiffBps = forward.minDiffBps();

            // Determine the average locked royalty per token unit
            uint256 lockedRoyaltyPerUnit;
            bytes32 itemHash = keccak256(
                abi.encode(listingDetails.token, listingDetails.identifier)
            );
            if (listingDetails.itemType == ISeaport.ItemType.ERC721) {
                lockedRoyaltyPerUnit = erc721Locks[itemHash].royalty;
            } else {
                lockedRoyaltyPerUnit =
                    erc1155Locks[itemHash].royalty /
                    erc1155Locks[itemHash].amount;
            }

            // Fetch the item's royalties
            (
                address[] memory royaltyRecipients,
                uint256[] memory royaltyAmounts
            ) = forward.royaltyEngine().getRoyaltyView(
                    listingDetails.token,
                    listingDetails.identifier,
                    totalPrice
                );

            // Ensure the royalties are present in the payment items
            uint256 totalRoyaltyAmount;
            uint256 diff = paymentsLength - royaltyAmounts.length;
            for (uint256 i = diff; i < paymentsLength; ) {
                if (
                    payments[i].recipient != royaltyRecipients[i - diff] ||
                    payments[i].amount != royaltyAmounts[i - diff]
                ) {
                    revert InvalidListing();
                }

                totalRoyaltyAmount += royaltyAmounts[i - diff];

                unchecked {
                    ++i;
                }
            }

            uint256 currentRoyaltyPerUnit = totalRoyaltyAmount /
                listingDetails.amount;
            if (
                currentRoyaltyPerUnit <
                (lockedRoyaltyPerUnit * minDiffBps) / 10000
            ) {
                revert InvalidListing();
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
            order.conduitKey = seaportConduitKey;
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
        // Only the protocol can send tokens
        if (operator != address(forward)) {
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
        // Only the protocol can send tokens
        if (operator != address(forward)) {
            revert Unauthorized();
        }

        return this.onERC1155Received.selector;
    }
}
