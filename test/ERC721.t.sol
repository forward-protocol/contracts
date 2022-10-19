// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {Merkle} from "murky/Merkle.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";

import {Forward} from "../src/Forward.sol";
import {ISeaport} from "../src/interfaces/ISeaport.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";

contract NFT is ERC721 {
    address[] private recipients;
    uint256[] private bps;

    constructor(address[] memory _recipients, uint256[] memory _bps)
        ERC721("NFT", "NFT")
    {
        setRoyalties(_recipients, _bps);
    }

    function mint(uint256 tokenId) external {
        _mint(msg.sender, tokenId);
    }

    function setRoyalties(address[] memory _recipients, uint256[] memory _bps)
        public
    {
        // Clear old royalties
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

contract ERC721Test is Test {
    Forward internal forward;

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
        uint96 unitPrice,
        uint128 amount,
        address[] memory royaltyRecipients,
        uint256[] memory royaltyBps
    )
        internal
        returns (
            NFT nft,
            Forward.Order memory order,
            bytes memory signature
        )
    {
        nft = new NFT(royaltyRecipients, royaltyBps);

        address maker = vm.addr(makerPk);

        // Setup vault together with balances/approvals
        vm.startPrank(maker);
        WETH.deposit{value: unitPrice * amount}();
        WETH.approve(address(forward), unitPrice * amount);
        vm.stopPrank();

        // Generate bid
        order = Forward.Order({
            orderKind: Forward.OrderKind.BID,
            itemKind: identifierOrCriteria < 10000
                ? Forward.ItemKind.ERC721
                : Forward.ItemKind.ERC721_WITH_CRITERIA,
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
                    forward.getOrderHash(order)
                )
            )
        );
        signature = abi.encodePacked(r, s, v);
    }

    function generateSeaportListing(
        uint256 makerPk,
        NFT nft,
        uint256 identifier,
        uint256 unitPrice
    ) internal returns (ISeaport.Order memory order) {
        address maker = vm.addr(makerPk);

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
        parameters.offerer = address(forward);
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
        parameters.conduitKey = forward.seaportConduitKey();
        parameters.totalOriginalConsiderationItems = 1 + royaltiesCount;

        // Populate the listing' offer items
        parameters.offer[0] = ISeaport.OfferItem(
            ISeaport.ItemType.ERC721,
            address(nft),
            identifier,
            1,
            1
        );

        // Populate the listing's consideration items
        parameters.consideration[0] = ISeaport.ConsiderationItem(
            ISeaport.ItemType.NATIVE,
            address(0),
            0,
            (unitPrice * (10000 - totalRoyaltyBps)) / 10000,
            (unitPrice * (10000 - totalRoyaltyBps)) / 10000,
            parameters.offerer
        );
        for (uint256 i = 0; i < royaltiesCount; i++) {
            parameters.consideration[i + 1] = ISeaport.ConsiderationItem(
                ISeaport.ItemType.NATIVE,
                address(0),
                0,
                (unitPrice * royaltyBps[i]) / 10000,
                (unitPrice * royaltyBps[i]) / 10000,
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
                    forward.SEAPORT_DOMAIN_SEPARATOR(),
                    forward.SEAPORT().getOrderHash(components)
                )
            )
        );
        bytes memory signature = abi.encodePacked(r, s, v);

        // Generate payment data from the consideration items
        Forward.Payment[] memory payments = new Forward.Payment[](
            parameters.consideration.length
        );
        for (uint256 i = 0; i < parameters.consideration.length; i++) {
            payments[i] = Forward.Payment(
                parameters.consideration[i].startAmount,
                parameters.consideration[i].recipient
            );
        }

        order.parameters = parameters;
        // Encode the listing data in the EIP1271 order signature
        order.signature = abi.encode(
            Forward.SeaportListingDetails({
                maker: maker,
                itemType: ISeaport.ItemType.ERC721,
                token: address(nft),
                identifier: identifier,
                amount: 1,
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
        uint96 unitPrice = 1 ether;
        (
            address[] memory royaltyRecipients,
            uint256[] memory royaltyBps,
            uint256 totalBps
        ) = generateRoyalties(3, 0);

        (
            NFT nft,
            Forward.Order memory order,
            bytes memory signature
        ) = generateForwardBid(
                alicePk,
                identifier,
                unitPrice,
                1,
                royaltyRecipients,
                royaltyBps
            );

        // Fill bid
        vm.startPrank(bob);
        nft.mint(identifier);
        nft.setApprovalForAll(address(forward), true);
        forward.fillBid(
            Forward.FillDetails({
                order: order,
                signature: signature,
                fillAmount: 1
            })
        );
        vm.stopPrank();

        // Ensure the taker got the payment from the bid
        require(WETH.balanceOf(bob) == unitPrice);

        // Ensure the token is now inside the protocol
        require(nft.ownerOf(identifier) == address(forward));

        (address owner, uint96 priceAcquiredAt) = forward.erc721Ownerships(
            keccak256(abi.encode(address(nft), identifier))
        );
        require(owner == alice);
        require(priceAcquiredAt == unitPrice);

        // Cannot fill an order for which the fillable quantity got to zero
        vm.expectRevert(Forward.InsufficientAmountAvailable.selector);
        vm.prank(bob);
        forward.fillBid(
            Forward.FillDetails({
                order: order,
                signature: signature,
                fillAmount: 1
            })
        );
    }

    function testFillCriteriaBid() public {
        Merkle merkle = new Merkle();

        bytes32[] memory identifiers = new bytes32[](4);
        identifiers[0] = keccak256(abi.encode(uint256(1)));
        identifiers[1] = keccak256(abi.encode(uint256(2)));
        identifiers[2] = keccak256(abi.encode(uint256(3)));
        identifiers[3] = keccak256(abi.encode(uint256(4)));

        uint256 criteria = uint256(merkle.getRoot(identifiers));

        uint256 identifier = 1;
        bytes32[] memory criteriaProof = merkle.getProof(identifiers, 0);

        uint96 unitPrice = 1 ether;
        (
            address[] memory royaltyRecipients,
            uint256[] memory royaltyBps,
            uint256 totalBps
        ) = generateRoyalties(3, 0);

        (
            NFT nft,
            Forward.Order memory order,
            bytes memory signature
        ) = generateForwardBid(
                alicePk,
                criteria,
                unitPrice,
                1,
                royaltyRecipients,
                royaltyBps
            );

        // Fill bid
        vm.startPrank(bob);
        nft.mint(identifier);
        nft.setApprovalForAll(address(forward), true);
        forward.fillBidWithCriteria(
            Forward.FillDetails({
                order: order,
                signature: signature,
                fillAmount: 1
            }),
            identifier,
            criteriaProof
        );
        vm.stopPrank();

        // Ensure the taker got the payment from the bid
        require(WETH.balanceOf(bob) == unitPrice);

        // Ensure the token is now inside the protocol
        require(nft.ownerOf(identifier) == address(forward));

        (address owner, uint96 priceAcquiredAt) = forward.erc721Ownerships(
            keccak256(abi.encode(address(nft), identifier))
        );
        require(owner == alice);
        require(priceAcquiredAt == unitPrice);
    }

    function testListingWithinTheProtocol() public {
        uint256 identifier = 1;
        uint96 bidUnitPrice = 1 ether;
        (
            address[] memory royaltyRecipients,
            uint256[] memory royaltyBps,
            uint256 totalBps
        ) = generateRoyalties(3, 0);

        (
            NFT nft,
            Forward.Bid memory bid,
            bytes memory signature
        ) = generateForwardBid(
                alicePk,
                identifier,
                bidUnitPrice,
                1,
                royaltyRecipients,
                royaltyBps
            );

        // Fill bid
        vm.startPrank(bob);
        nft.mint(identifier);
        nft.setApprovalForAll(address(forward), true);
        forward.fill(
            Forward.FillDetails({
                order: order,
                signature: signature,
                fillAmount: 1
            })
        );
        vm.stopPrank();

        uint256 listingPrice = 1.5 ether;
        ISeaport.Order memory order = generateSeaportListing(
            alicePk,
            nft,
            identifier,
            listingPrice
        );

        // Fill listing
        vm.startPrank(carol);
        vault.SEAPORT().fulfillOrder{value: listingPrice}(order, bytes32(0));
        vm.stopPrank();

        uint256 makerWETHBalanceBefore = WETH.balanceOf(alice);

        // Unlock royalties
        vm.prank(alice);
        vault.unlockERC721(nft, identifier);

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
                (bidUnitPrice * totalBps) / 10000
        );
    }

    // function testListingFromVaultWithAutomaticUnlock() public {
    //     uint256 identifier = 1;
    //     uint256 bidUnitPrice = 1 ether;
    //     (
    //         address[] memory royaltyRecipients,
    //         uint256[] memory royaltyBps,
    //     ) = generateRoyalties(2, 0);

    //     (
    //         NFT nft,
    //         Vault vault,
    //         Forward.Bid memory bid,
    //         bytes memory signature
    //     ) = generateForwardBid(
    //             alicePk,
    //             identifier,
    //             bidUnitPrice,
    //             1,
    //             royaltyRecipients,
    //             royaltyBps
    //         );

    //     // Fill bid
    //     vm.startPrank(bob);
    //     nft.mint(identifier);
    //     nft.setApprovalForAll(address(forward), true);
    //     forward.fill(
    //         Forward.FillDetails({bid: bid, signature: signature, fillAmount: 1})
    //     );
    //     vm.stopPrank();

    //     uint256 listingPrice = 1.5 ether;
    //     ISeaport.Order memory order = generateSeaportListing(
    //         alicePk,
    //         nft,
    //         identifier,
    //         listingPrice
    //     );

    //     // Tweak the order to include the unlock consideration as a tip
    //     ISeaport.ConsiderationItem[]
    //         memory consideration = new ISeaport.ConsiderationItem[](
    //             order.parameters.consideration.length + 1
    //         );
    //     for (uint256 i = 0; i < order.parameters.consideration.length; i++) {
    //         consideration[i] = order.parameters.consideration[i];
    //     }
    //     consideration[consideration.length - 1] = ISeaport.ConsiderationItem({
    //         itemType: ISeaport.ItemType.ERC1155,
    //         token: address(vaultUnlocker),
    //         // id
    //         identifierOrCriteria: uint256(uint160(address(nft))),
    //         // value
    //         startAmount: identifier,
    //         endAmount: identifier,
    //         // to
    //         recipient: address(vault)
    //     });
    //     order.parameters.consideration = consideration;

    //     // Fill listing
    //     vm.startPrank(carol);
    //     vault.SEAPORT().fulfillOrder{value: listingPrice}(order, bytes32(0));
    //     vm.stopPrank();

    //     // Ensure the royalties got unlocked from the vault
    //     require(WETH.balanceOf(address(vault)) == 0);
    // }

    // function testForceUnlock() public {
    //     uint256 identifier = 1;
    //     uint256 bidUnitPrice = 1 ether;
    //     (
    //         address[] memory royaltyRecipients,
    //         uint256[] memory royaltyBps,
    //     ) = generateRoyalties(2, 0);

    //     (
    //         NFT nft,
    //         Vault vault,
    //         Forward.Bid memory bid,
    //         bytes memory signature
    //     ) = generateForwardBid(
    //             alicePk,
    //             identifier,
    //             bidUnitPrice,
    //             1,
    //             royaltyRecipients,
    //             royaltyBps
    //         );

    //     // Fill bid
    //     vm.startPrank(bob);
    //     nft.mint(identifier);
    //     nft.setApprovalForAll(address(forward), true);
    //     forward.fill(
    //         Forward.FillDetails({bid: bid, signature: signature, fillAmount: 1})
    //     );
    //     vm.stopPrank();

    //     vm.prank(alice);
    //     vault.unlockERC721(nft, identifier);

    //     // Ensure the royalties got unlocked from the vault
    //     require(WETH.balanceOf(address(vault)) == 0);

    //     // Ensure the royalties got paid
    //     for (uint256 i = 0; i < royaltyBps.length; i++) {
    //         require(WETH.balanceOf(royaltyRecipients[i]) == bidUnitPrice * royaltyBps[i] / 10000);
    //     }
    // }

    // function testUpdatedRoyalties() public {
    //     uint256 identifier = 1;
    //     uint256 bidUnitPrice = 1 ether;
    //     (
    //         address[] memory royaltyRecipients,
    //         uint256[] memory royaltyBps,
    //     ) = generateRoyalties(2, 0);

    //     (
    //         NFT nft,
    //         Vault vault,
    //         Forward.Bid memory bid,
    //         bytes memory signature
    //     ) = generateForwardBid(
    //             alicePk,
    //             identifier,
    //             bidUnitPrice,
    //             1,
    //             royaltyRecipients,
    //             royaltyBps
    //         );

    //     // Fill bid
    //     vm.startPrank(bob);
    //     nft.mint(identifier);
    //     nft.setApprovalForAll(address(forward), true);
    //     forward.fill(
    //         Forward.FillDetails({bid: bid, signature: signature, fillAmount: 1})
    //     );
    //     vm.stopPrank();

    //     // Update royalties
    //     (
    //         address[] memory newRoyaltyRecipients,
    //         uint256[] memory newRoyaltyBps,
    //         uint256 newTotalBps
    //     ) = generateRoyalties(3, 1);
    //     nft.setRoyalties(newRoyaltyRecipients, newRoyaltyBps);

    //     // Fetch the locked royalty amount
    //     uint256 lockedRoyalty = vault.erc721Locks(keccak256(abi.encode(address(nft), identifier)));

    //     vm.prank(alice);
    //     vault.unlockERC721(nft, identifier);

    //     // Ensure the royalties got paid to the new recipients
    //     for (uint256 i = 0; i < newRoyaltyBps.length; i++) {
    //         require(WETH.balanceOf(newRoyaltyRecipients[i]) == lockedRoyalty * newRoyaltyBps[i] / newTotalBps);
    //     }
    // }

    // function testLowListingRoyalties() public {
    //     uint256 identifier = 1;
    //     uint256 bidUnitPrice = 1 ether;
    //     (
    //         address[] memory royaltyRecipients,
    //         uint256[] memory royaltyBps,
    //     ) = generateRoyalties(3, 0);

    //     (
    //         NFT nft,
    //         Vault vault,
    //         Forward.Bid memory bid,
    //         bytes memory signature
    //     ) = generateForwardBid(
    //             alicePk,
    //             identifier,
    //             bidUnitPrice,
    //             1,
    //             royaltyRecipients,
    //             royaltyBps
    //         );

    //     // Fill bid
    //     vm.startPrank(bob);
    //     nft.mint(identifier);
    //     nft.setApprovalForAll(address(forward), true);
    //     forward.fill(
    //         Forward.FillDetails({bid: bid, signature: signature, fillAmount: 1})
    //     );
    //     vm.stopPrank();

    //     uint256 minDiffBps = forward.minDiffBps();

    //     uint256 listingPrice = bidUnitPrice * minDiffBps / 10000 - 1;
    //     ISeaport.Order memory order = generateSeaportListing(
    //         alicePk,
    //         nft,
    //         identifier,
    //         listingPrice
    //     );

    //     // Cannot fill an order for which the royalties are not within the protocol threshold
    //     vm.startPrank(carol);
    //     ISeaport seaport = vault.SEAPORT();
    //     vm.expectRevert(Vault.InvalidListing.selector);
    //     seaport.fulfillOrder{value: listingPrice}(order, bytes32(0));
    //     vm.stopPrank();
    // }
}
