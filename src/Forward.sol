// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";

import {Vault} from "./Vault.sol";
import {IRoyaltyEngine} from "./interfaces/IRoyaltyEngine.sol";

contract Forward {
    using SafeERC20 for IERC20;

    // --- Structs ---

    struct Bid {
        address maker;
        IERC721 collection;
        uint256 tokenId;
        uint256 price;
        uint256 expiration;
    }

    // --- Errors ---

    error Unauthorized();
    error VaultAlreadyExists();
    error VaultIsMissing();

    // --- Constants ---

    IERC20 public constant WETH =
        IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    IRoyaltyEngine public constant ROYALTY_ENGINE =
        IRoyaltyEngine(0x0385603ab55642cb4Dd5De3aE9e306809991804f);

    // --- Fields ---

    Bid[] public bids;
    mapping(address => Vault) public vaults;

    // --- Public methods ---

    function createVault() external returns (Vault vault) {
        if (address(vaults[msg.sender]) != address(0)) {
            revert VaultAlreadyExists();
        }

        vault = new Vault(msg.sender);
        vaults[msg.sender] = vault;
    }

    function createBid(Bid calldata bid) external returns (uint256 id) {
        address maker = bid.maker;

        if (msg.sender != maker) {
            revert Unauthorized();
        }
        if (address(vaults[maker]) == address(0)) {
            revert VaultIsMissing();
        }

        id = bids.length;
        bids.push(
            Bid(maker, bid.collection, bid.tokenId, bid.price, bid.expiration)
        );
    }

    function acceptBid(uint256 id) external {
        Bid memory bid = bids[id];

        address maker = bid.maker;
        Vault vault = vaults[maker];
        if (address(vault) == address(0)) {
            revert VaultIsMissing();
        }

        (address[] memory recipients, uint256[] memory amounts) = ROYALTY_ENGINE
            .getRoyaltyView(address(bid.collection), bid.tokenId, bid.price);

        uint256 totalRoyaltyAmount;
        uint256 length = amounts.length;
        for (uint256 i = 0; i < length; ) {
            totalRoyaltyAmount += amounts[i];

            unchecked {
                ++i;
            }
        }

        WETH.safeTransferFrom(
            maker,
            msg.sender,
            bid.price - totalRoyaltyAmount
        );
        WETH.safeTransferFrom(maker, address(vault), totalRoyaltyAmount);

        Vault.ItemRoyalties memory royalties;
        royalties.exists = true;
        royalties.recipients = recipients;
        royalties.amounts = amounts;

        // Use on received hook
        bid.collection.safeTransferFrom(msg.sender, address(this), bid.tokenId);
        bid.collection.approve(address(vault), bid.tokenId);
        vault.lock(bid.collection, bid.tokenId, royalties);
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
