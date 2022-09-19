// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {ECDSA} from "openzeppelin/utils/cryptography/ECDSA.sol";

import {IRoyaltyEngine} from "./interfaces/IRoyaltyEngine.sol";
import {ISeaport} from "./interfaces/ISeaport.sol";

contract Vault {
    using SafeERC20 for IERC20;

    // --- Struct ---

    struct ItemRoyalties {
        bool exists;
        address[] recipients;
        uint256[] amounts;
    }

    // --- Errors ---

    error InvalidListing();
    error ItemNotLocked();
    error Unauthorized();

    // --- Constants ---

    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    ISeaport public constant SEAPORT =
        ISeaport(0x00000000006c3852cbEf3e08E8dF289169EdE581);

    IRoyaltyEngine public constant ROYALTY_ENGINE =
        IRoyaltyEngine(0x0385603ab55642cb4Dd5De3aE9e306809991804f);

    bytes32 public immutable SEAPORT_DOMAIN_SEPARATOR;

    // --- Private fields ---

    mapping(bytes32 => ItemRoyalties) private itemRoyalties;

    // --- Public fields ---

    address public deployer;
    address public owner;

    // --- Constructor ---

    constructor(address _owner) {
        deployer = msg.sender;
        owner = _owner;

        (, SEAPORT_DOMAIN_SEPARATOR, ) = SEAPORT.information();
    }

    // --- Restricted methods ---

    function lock(
        IERC721 collection,
        uint256 tokenId,
        ItemRoyalties calldata royalties
    ) external {
        if (msg.sender != deployer) {
            revert Unauthorized();
        }

        bytes32 itemHash = keccak256(abi.encode(collection, tokenId));
        if (itemRoyalties[itemHash].exists) {
            unlock(collection, tokenId);
        }

        itemRoyalties[itemHash].exists = royalties.exists;
        itemRoyalties[itemHash].recipients = royalties.recipients;
        itemRoyalties[itemHash].amounts = royalties.amounts;

        collection.safeTransferFrom(msg.sender, address(this), tokenId);
        collection.setApprovalForAll(address(SEAPORT), true);
    }

    function unlock(IERC721 collection, uint256 tokenId) public {
        if (msg.sender != owner) {
            revert Unauthorized();
        }

        bytes32 itemHash = keccak256(abi.encode(collection, tokenId));
        if (!itemRoyalties[itemHash].exists) {
            revert ItemNotLocked();
        }

        address itemOwner = collection.ownerOf(tokenId);

        ItemRoyalties memory royalties = itemRoyalties[itemHash];
        uint256 length = royalties.amounts.length;
        for (uint256 i = 0; i < length; ) {
            WETH.safeTransfer(
                itemOwner == address(this)
                    ? royalties.recipients[i]
                    : msg.sender,
                royalties.amounts[i]
            );

            unchecked {
                ++i;
            }
        }

        if (itemOwner == address(this)) {
            collection.safeTransferFrom(address(this), msg.sender, tokenId);
        }

        delete itemRoyalties[itemHash];
    }

    // --- EIP1271 ---

    function isValidSignature(bytes32 digest, bytes memory signature)
        external
        view
        returns (bytes4)
    {
        (
            address collection,
            uint256 tokenId,
            uint256 startTime,
            uint256 endTime,
            uint256 salt,
            ISeaport.ConsiderationItem[] memory consideration,
            bytes memory orderSignature
        ) = abi.decode(
                signature,
                (
                    address,
                    uint256,
                    uint256,
                    uint256,
                    uint256,
                    ISeaport.ConsiderationItem[],
                    bytes
                )
            );

        {
            bytes32 itemHash = keccak256(abi.encode(collection, tokenId));
            if (!itemRoyalties[itemHash].exists) {
                revert ItemNotLocked();
            }
        }

        ISeaport.OfferItem[] memory offer = new ISeaport.OfferItem[](1);
        offer[0] = ISeaport.OfferItem(
            ISeaport.ItemType.ERC721,
            collection,
            tokenId,
            1,
            1
        );

        uint256 totalPrice;
        uint256 considerationLength = consideration.length;
        {
            for (uint256 i = 0; i < considerationLength; ) {
                if (
                    consideration[i].itemType != ISeaport.ItemType.NATIVE ||
                    consideration[i].startAmount != consideration[i].endAmount
                ) {
                    revert InvalidListing();
                }

                totalPrice += consideration[i].endAmount;

                unchecked {
                    ++i;
                }
            }
        }

        {
            (
                address[] memory recipients,
                uint256[] memory amounts
            ) = ROYALTY_ENGINE.getRoyaltyView(collection, tokenId, totalPrice);

            uint256 royaltiesLength = amounts.length;
            uint256 diff = considerationLength - royaltiesLength;
            for (uint256 i = considerationLength - 1; i >= diff; ) {
                if (
                    consideration[i].recipient != recipients[i - diff] ||
                    consideration[i].endAmount != amounts[i - diff]
                ) {
                    revert InvalidListing();
                }

                unchecked {
                    --i;
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
            // order.orderType = ISeaport.OrderType.FULL_OPEN;
            order.startTime = startTime;
            order.endTime = endTime;
            // order.zoneHash = bytes32(0);
            order.salt = salt;
            // order.conduitKey = bytes32(0);
            order.counter = SEAPORT.getCounter(address(this));

            orderHash = SEAPORT.getOrderHash(order);
        }
        if (
            digest !=
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    SEAPORT_DOMAIN_SEPARATOR,
                    orderHash
                )
            )
        ) {
            revert InvalidListing();
        }

        address signer = ECDSA.recover(digest, orderSignature);
        if (signer != owner) {
            revert InvalidListing();
        }

        return 0x1626ba7e;
    }

    // --- EIP721 ---

    function onERC721Received(
        address, // operator
        address, // from
        uint256, // tokenId
        bytes calldata // data
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
