// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {ERC1155} from "openzeppelin/token/ERC1155/ERC1155.sol";

import {Forward} from "../src/Forward.sol";
import {Vault} from "../src/Vault.sol";
import {ERC1155VaultUnlocker} from "../src/VaultUnlocker.sol";
import {ISeaport} from "../src/interfaces/ISeaport.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";

contract NFT is ERC1155 {
    address[] private recipients;
    uint256[] private bps;

    constructor(address[] memory _recipients, uint256[] memory _bps)
        ERC1155("")
    {
        setRoyalties(_recipients, _bps);
    }

    function mint(uint256 tokenId, uint256 amount) external {
        _mint(msg.sender, tokenId, amount, "");
    }

    function setRoyalties(address[] memory _recipients, uint256[] memory _bps)
        public
    {
        delete recipients;
        delete bps;

        for (uint256 i = 0; i < _bps.length; i++) {
            recipients.push(_recipients[i]);
            bps.push(_bps[i]);
        }
    }

    // Use the Manifold standard to allow multiple royalties
    function getRoyalties(
        uint256 // identifier
    )
        external
        view
        returns (address[] memory _recipients, uint256[] memory _bps)
    {
        _recipients = recipients;
        _bps = bps;
    }
}

contract ERC1155Test is Test {
    Forward internal forward;
    ERC1155VaultUnlocker internal vaultUnlocker;

    IWETH internal WETH;

    // Setup wallets
    uint256 internal alicePk = uint256(0x01);
    address internal alice = vm.addr(alicePk);
    address internal bob = address(0x02);
    address internal carol = address(0x03);
    address internal dan = address(0x04);
    address internal emily = address(0x05);

    function setUp() public {
        forward = new Forward();
        vaultUnlocker = new ERC1155VaultUnlocker();

        WETH = IWETH(address(forward.WETH()));

        // Grant some ETH to all wallets
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(dan, 100 ether);
        vm.deal(emily, 100 ether);
    }

    // Helper methods

    function generateRoyalties(uint256 count, uint256 seed)
        internal
        pure
        returns (
            address[] memory recipients,
            uint256[] memory bps,
            uint256 totalBps
        )
    {
        recipients = new address[](count);
        bps = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            // Generate "pseudo-random" royalty recipient and bps
            recipients[i] = address(uint160((seed + i + 1) * 9999));
            bps[i] = (i + 1) * 50;

            totalBps += bps[i];
        }
    }

    function generateForwardBid(
        uint256 makerPk,
        uint256 identifierOrCriteria,
        uint256 unitPrice,
        uint128 amount,
        address[] memory royaltyRecipients,
        uint256[] memory royaltyBps
    )
        internal
        returns (
            NFT nft,
            Vault vault,
            Forward.Bid memory bid,
            bytes memory signature
        )
    {
        nft = new NFT(royaltyRecipients, royaltyBps);

        address maker = vm.addr(makerPk);

        // Setup vault together with balances/approvals
        vm.startPrank(maker);
        vault = forward.createVault();
        WETH.deposit{value: unitPrice * amount}();
        WETH.approve(address(forward), unitPrice * amount);
        vm.stopPrank();

        // Generate bid
        bid = Forward.Bid({
            itemKind: identifierOrCriteria < 10000
                ? Forward.ItemKind.ERC1155
                : Forward.ItemKind.ERC1155_WITH_CRITERIA,
            maker: maker,
            token: address(nft),
            identifierOrCriteria: identifierOrCriteria,
            unitPrice: unitPrice,
            amount: amount,
            salt: 0,
            expiration: block.timestamp + 1
        });

        // Sign bid
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            makerPk,
            keccak256(
                abi.encodePacked(
                    hex"1901",
                    forward.DOMAIN_SEPARATOR(),
                    forward.getBidHash(bid)
                )
            )
        );
        signature = abi.encodePacked(r, s, v);
    }

    function generateSeaportListing(
        uint256 makerPk,
        NFT nft,
        uint256 identifier,
        uint256 amount,
        uint256 unitPrice
    ) internal returns (ISeaport.Order memory order) {
        address maker = vm.addr(makerPk);
        Vault vault = forward.vaults(maker);

        // Fetch the item's royalties
        (address[] memory royaltyRecipients, uint256[] memory royaltyBps) = nft
            .getRoyalties(identifier);
        uint256 royaltiesCount = royaltyBps.length;

        // Compute the total royalty bps
        uint256 totalRoyaltyBps;
        for (uint256 i = 0; i < royaltiesCount; i++) {
            totalRoyaltyBps += royaltyBps[i];
        }

        // Create Seaport listing
        ISeaport.OrderParameters memory parameters;
        parameters.offerer = address(vault);
        // parameters.zone = address(0);
        parameters.offer = new ISeaport.OfferItem[](1);
        parameters.consideration = new ISeaport.ConsiderationItem[](
            1 + royaltiesCount
        );
        parameters.orderType = ISeaport.OrderType.PARTIAL_OPEN;
        parameters.startTime = block.timestamp;
        parameters.endTime = block.timestamp + 1;
        // parameters.zoneHash = bytes32(0);
        // parameters.salt = 0;
        parameters.conduitKey = vault.SEAPORT_OPENSEA_CONDUIT_KEY();
        parameters.totalOriginalConsiderationItems = 1 + royaltiesCount;

        // Populate the listing' offer items
        parameters.offer[0] = ISeaport.OfferItem(
            ISeaport.ItemType.ERC1155,
            address(nft),
            identifier,
            amount,
            amount
        );

        // Populate the listing's consideration items
        parameters.consideration[0] = ISeaport.ConsiderationItem(
            ISeaport.ItemType.NATIVE,
            address(0),
            0,
            (unitPrice * amount * (10000 - totalRoyaltyBps)) / 10000,
            (unitPrice * amount * (10000 - totalRoyaltyBps)) / 10000,
            parameters.offerer
        );
        for (uint256 i = 0; i < royaltiesCount; i++) {
            parameters.consideration[i + 1] = ISeaport.ConsiderationItem(
                ISeaport.ItemType.NATIVE,
                address(0),
                0,
                (unitPrice * amount * royaltyBps[i]) / 10000,
                (unitPrice * amount * royaltyBps[i]) / 10000,
                royaltyRecipients[i]
            );
        }

        // Sign listing

        ISeaport.OrderComponents memory components = ISeaport.OrderComponents(
            parameters.offerer,
            parameters.zone,
            parameters.offer,
            parameters.consideration,
            parameters.orderType,
            parameters.startTime,
            parameters.endTime,
            parameters.zoneHash,
            parameters.salt,
            parameters.conduitKey,
            0
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            alicePk,
            keccak256(
                abi.encodePacked(
                    hex"1901",
                    vault.SEAPORT_DOMAIN_SEPARATOR(),
                    vault.SEAPORT().getOrderHash(components)
                )
            )
        );
        bytes memory signature = abi.encodePacked(r, s, v);

        // Generate payment data from the consideration items
        Vault.Payment[] memory payments = new Vault.Payment[](
            parameters.consideration.length
        );
        for (uint256 i = 0; i < parameters.consideration.length; i++) {
            payments[i] = Vault.Payment(
                parameters.consideration[i].startAmount,
                parameters.consideration[i].recipient
            );
        }

        order.parameters = parameters;
        // Encode the listing data in the EIP1271 order signature
        order.signature = abi.encode(
            Vault.SeaportListingDetails({
                itemType: ISeaport.ItemType.ERC1155,
                token: address(nft),
                identifier: identifier,
                amount: amount,
                startTime: parameters.startTime,
                endTime: parameters.endTime,
                salt: parameters.salt,
                payments: payments
            }),
            signature
        );
    }

    // Tests

    function testFillSingleTokenBid() public {
        uint256 identifier = 1;
        uint128 amount = 10;
        uint128 fillAmount = 3;
        uint256 unitPrice = 0.1 ether;
        (
            address[] memory royaltyRecipients,
            uint256[] memory royaltyBps,
            uint256 totalBps
        ) = generateRoyalties(3, 0);

        (
            NFT nft,
            Vault vault,
            Forward.Bid memory bid,
            bytes memory signature
        ) = generateForwardBid(
                alicePk,
                identifier,
                unitPrice,
                amount,
                royaltyRecipients,
                royaltyBps
            );

        // Fill bid
        vm.startPrank(bob);
        nft.mint(identifier, fillAmount);
        nft.setApprovalForAll(address(forward), true);
        forward.fill(
            Forward.FillDetails({
                bid: bid,
                signature: signature,
                fillAmount: fillAmount
            })
        );
        vm.stopPrank();

        // Ensure the taker got the payment from the bid
        require(
            WETH.balanceOf(bob) ==
                (unitPrice * fillAmount * (10000 - totalBps)) / 10000
        );

        // Ensure the royalties got locked in the maker's vault
        require(
            WETH.balanceOf(address(vault)) ==
                (unitPrice * fillAmount * totalBps) / 10000
        );

        // Ensure the token got locked in the maker's vault
        require(nft.balanceOf(address(vault), identifier) == fillAmount);

        // Cannot fill more than the available fill amount
        vm.expectRevert(Forward.InsufficientAmountAvailable.selector);
        vm.prank(bob);
        forward.fill(
            Forward.FillDetails({
                bid: bid,
                signature: signature,
                fillAmount: amount - fillAmount + 1
            })
        );
    }

    function testListingFromVault() public {
        uint256 identifier = 1;
        uint128 amount = 5;
        uint128 fillAmount = 3;
        uint256 bidUnitPrice = 1 ether;
        (
            address[] memory royaltyRecipients,
            uint256[] memory royaltyBps,
            uint256 totalBps
        ) = generateRoyalties(3, 0);

        (
            NFT nft,
            Vault vault,
            Forward.Bid memory bid,
            bytes memory signature
        ) = generateForwardBid(
                alicePk,
                identifier,
                bidUnitPrice,
                amount,
                royaltyRecipients,
                royaltyBps
            );

        // Fill bid
        vm.startPrank(bob);
        nft.mint(identifier, fillAmount);
        nft.setApprovalForAll(address(forward), true);
        forward.fill(
            Forward.FillDetails({
                bid: bid,
                signature: signature,
                fillAmount: fillAmount
            })
        );
        vm.stopPrank();

        uint256 listingUnitPrice = 1.5 ether;
        ISeaport.Order memory order = generateSeaportListing(
            alicePk,
            nft,
            identifier,
            fillAmount,
            listingUnitPrice
        );

        // Fill listing
        vm.startPrank(carol);
        vault.SEAPORT().fulfillOrder{value: listingUnitPrice * fillAmount}(
            order,
            bytes32(0)
        );
        vm.stopPrank();

        uint256 makerWETHBalanceBefore = WETH.balanceOf(alice);

        // Unlock royalties
        vm.prank(alice);
        vault.unlockERC1155(nft, identifier, fillAmount);

        uint256 makerWETHBalanceAfter = WETH.balanceOf(alice);

        // Ensure the royalties got unlocked from the vault
        require(WETH.balanceOf(address(vault)) == 0);

        // Ensure no royalties got paid
        for (uint256 i = 0; i < royaltyBps.length; i++) {
            require(WETH.balanceOf(royaltyRecipients[i]) == 0);
        }

        // Ensure the maker got the locked royalties refunded
        require(
            makerWETHBalanceAfter - makerWETHBalanceBefore ==
                (bidUnitPrice * fillAmount * totalBps) / 10000
        );
    }

    function testUnlocks() public {
        uint256 identifier = 1;
        uint128 amount = 5;
        uint128 bidFillAmount = 3;
        uint256 bidUnitPrice = 1 ether;
        (
            address[] memory royaltyRecipients,
            uint256[] memory royaltyBps,
            uint256 totalBps
        ) = generateRoyalties(3, 0);

        (
            NFT nft,
            Vault vault,
            Forward.Bid memory bid,
            bytes memory signature
        ) = generateForwardBid(
                alicePk,
                identifier,
                bidUnitPrice,
                amount,
                royaltyRecipients,
                royaltyBps
            );

        // Fill bid
        vm.startPrank(bob);
        nft.mint(identifier, bidFillAmount);
        nft.setApprovalForAll(address(forward), true);
        forward.fill(
            Forward.FillDetails({
                bid: bid,
                signature: signature,
                fillAmount: bidFillAmount
            })
        );
        vm.stopPrank();

        uint256 listingUnitPrice = 1.5 ether;
        uint256 listingFillAmount = 1;
        ISeaport.Order memory order = generateSeaportListing(
            alicePk,
            nft,
            identifier,
            listingFillAmount,
            listingUnitPrice
        );

        // Fill listing
        vm.startPrank(carol);
        vault.SEAPORT().fulfillOrder{
            value: listingUnitPrice * listingFillAmount
        }(order, bytes32(0));
        vm.stopPrank();

        uint256 makerWETHBalanceBefore = WETH.balanceOf(alice);

        // Unlock royalties
        vm.prank(alice);
        vault.unlockERC1155(nft, identifier, bidFillAmount);

        uint256 makerWETHBalanceAfter = WETH.balanceOf(alice);

        // Ensure the royalties corresponding to the accepted listing's amount got refunded to the maker
        require(
            makerWETHBalanceAfter - makerWETHBalanceBefore ==
                (bidUnitPrice * listingFillAmount * totalBps) / 10000
        );

        // Ensure the royalties corresponding to the still locked amount got paid
        for (uint256 i = 0; i < royaltyBps.length; i++) {
            require(
                WETH.balanceOf(royaltyRecipients[i]) ==
                    (bidUnitPrice *
                        (bidFillAmount - listingFillAmount) *
                        royaltyBps[i]) /
                        10000
            );
        }
    }

    function testLowListingRoyalties() public {
        uint256 identifier = 1;
        uint128 amount = 4;
        uint128 fillAmount = 3;
        uint256 bidUnitPrice = 1 ether;
        (
            address[] memory royaltyRecipients,
            uint256[] memory royaltyBps,

        ) = generateRoyalties(3, 0);

        (
            NFT nft,
            Vault vault,
            Forward.Bid memory bid,
            bytes memory signature
        ) = generateForwardBid(
                alicePk,
                identifier,
                bidUnitPrice,
                amount,
                royaltyRecipients,
                royaltyBps
            );

        // Fill bid
        vm.startPrank(bob);
        nft.mint(identifier, fillAmount);
        nft.setApprovalForAll(address(forward), true);
        forward.fill(
            Forward.FillDetails({
                bid: bid,
                signature: signature,
                fillAmount: fillAmount
            })
        );
        vm.stopPrank();

        uint256 minDiffBps = forward.minDiffBps();

        uint256 listingAmount = 2;
        uint256 listingPrice = (bidUnitPrice * minDiffBps) / 10000 - 1;
        ISeaport.Order memory order = generateSeaportListing(
            alicePk,
            nft,
            identifier,
            listingAmount,
            listingPrice
        );

        // Cannot fill an order for which the royalties are not within the protocol threshold
        vm.startPrank(carol);
        ISeaport seaport = vault.SEAPORT();
        vm.expectRevert(Vault.InvalidListing.selector);
        seaport.fulfillOrder{value: listingPrice * listingAmount}(
            order,
            bytes32(0)
        );
        vm.stopPrank();
    }
}
