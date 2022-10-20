// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";
import {Merkle} from "murky/Merkle.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {ReservoirOracle} from "oracle/ReservoirOracle.sol";

import {Forward} from "../src/Forward.sol";
import {ReservoirPriceOracle} from "../src/ReservoirPriceOracle.sol";
import {ISeaport} from "../src/interfaces/ISeaport.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";

import "forge-std/console.sol";

contract ERC721Test is Test {
    using stdJson for string;

    ReservoirPriceOracle internal oracle;
    Forward internal forward;
    IWETH internal weth;

    address internal bayc = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D;
    address internal baycOwner = 0x8AD272Ac86c6C88683d9a60eb8ED57E6C304bB0C;
    uint256 internal baycIdentifier = 7090;

    // Setup wallets
    uint256 internal alicePk = uint256(0x01);
    address internal alice = vm.addr(alicePk);
    address internal bob = address(0x02);
    address internal carol = address(0x03);
    address internal dan = address(0x04);
    address internal emily = address(0x05);

    function setUp() public {
        vm.createSelectFork("mainnet");
        vm.warp(block.timestamp + 60);

        oracle = new ReservoirPriceOracle(
            0x32dA57E736E05f75aa4FaE2E9Be60FD904492726
        );
        forward = new Forward(address(oracle));
        weth = IWETH(address(forward.WETH()));

        // Grant some ETH to all wallets
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(dan, 100 ether);
        vm.deal(emily, 100 ether);
    }

    // Helper methods

    function generateForwardBid(
        uint256 makerPk,
        address token,
        uint256 identifierOrCriteria,
        uint256 unitPrice
    ) internal returns (Forward.Order memory order, bytes memory signature) {
        address maker = vm.addr(makerPk);

        // Prepare balance and approval
        vm.startPrank(maker);
        weth.deposit{value: unitPrice}();
        weth.approve(address(forward), unitPrice);
        vm.stopPrank();

        // Generate bid
        order = Forward.Order({
            orderKind: Forward.OrderKind.BID,
            itemKind: identifierOrCriteria < 10000
                ? Forward.ItemKind.ERC721
                : Forward.ItemKind.ERC721_WITH_CRITERIA,
            maker: maker,
            token: token,
            identifierOrCriteria: identifierOrCriteria,
            unitPrice: unitPrice,
            amount: 1,
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
        address token,
        uint256 identifier,
        uint256 unitPrice
    ) internal returns (ISeaport.Order memory order) {
        address maker = vm.addr(makerPk);

        // Fetch the item's royalties
        (
            address[] memory royaltyRecipients,
            uint256[] memory royaltyAmounts
        ) = forward.royaltyEngine().getRoyaltyView(
                token,
                identifier,
                unitPrice
            );

        uint256 royaltiesLength = royaltyRecipients.length;

        // Compute the total royalty bps
        uint256 totalRoyaltyAmount;
        for (uint256 i = 0; i < royaltiesLength; i++) {
            totalRoyaltyAmount += royaltyAmounts[i];
        }

        // Create Seaport listing
        ISeaport.OrderParameters memory parameters;
        parameters.offerer = address(forward);
        // parameters.zone = address(0);
        parameters.offer = new ISeaport.OfferItem[](1);
        parameters.consideration = new ISeaport.ConsiderationItem[](
            1 + royaltiesLength
        );
        parameters.orderType = ISeaport.OrderType.PARTIAL_OPEN;
        parameters.startTime = block.timestamp;
        parameters.endTime = block.timestamp + 1;
        // parameters.zoneHash = bytes32(0);
        // parameters.salt = 0;
        parameters.conduitKey = forward.seaportConduitKey();
        parameters.totalOriginalConsiderationItems = 1 + royaltiesLength;

        // Populate the listing's offer items
        parameters.offer[0] = ISeaport.OfferItem(
            ISeaport.ItemType.ERC721,
            token,
            identifier,
            1,
            1
        );

        // Populate the listing's consideration items
        parameters.consideration[0] = ISeaport.ConsiderationItem(
            ISeaport.ItemType.NATIVE,
            address(0),
            0,
            unitPrice - totalRoyaltyAmount,
            unitPrice - totalRoyaltyAmount,
            maker
        );
        for (uint256 i = 0; i < royaltiesLength; i++) {
            parameters.consideration[i + 1] = ISeaport.ConsiderationItem(
                ISeaport.ItemType.NATIVE,
                address(0),
                0,
                royaltyAmounts[i],
                royaltyAmounts[i],
                royaltyRecipients[i]
            );
        }

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

        // Sign the listing
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            makerPk,
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

        string[] memory args = new string[](3);
        args[0] = "bash";
        args[1] = "-c";
        args[
            2
        ] = "curl -s https://api.reservoir.tools/oracle/collections/floor-ask/v4?token=0xbc4ca0eda7647a8ab7c2061c2e118a18a936f13d:7090&kind=spot&twapSeconds=0";

        string memory rawOracleResponse = string(vm.ffi(args));
        ReservoirOracle.Message memory message = ReservoirOracle.Message({
            id: abi.decode(
                rawOracleResponse.parseRaw(".message.id"),
                (bytes32)
            ),
            payload: abi.decode(
                rawOracleResponse.parseRaw(".message.payload"),
                (bytes)
            ),
            timestamp: abi.decode(
                rawOracleResponse.parseRaw(".message.timestamp"),
                (uint256)
            ),
            signature: abi.decode(
                rawOracleResponse.parseRaw(".message.signature"),
                (bytes)
            )
        });

        order.parameters = parameters;
        // We encode the following in the EIP1271 signature:
        // - compacted listing data
        // - actual order signature
        // - oracle price message
        order.signature = abi.encode(
            Forward.SeaportListingDetails({
                itemType: ISeaport.ItemType.ERC721,
                token: token,
                identifier: identifier,
                amount: 1,
                startTime: parameters.startTime,
                endTime: parameters.endTime,
                salt: parameters.salt,
                payments: payments
            }),
            signature,
            abi.encode(message)
        );
    }

    function getTotalRoyaltyAmount(
        address token,
        uint256 identifier,
        uint256 price
    ) internal view returns (uint256) {
        (, uint256[] memory royaltyAmounts) = forward
            .royaltyEngine()
            .getRoyaltyView(token, identifier, price);

        uint256 totalRoyaltyAmount;
        for (uint256 i = 0; i < royaltyAmounts.length; i++) {
            totalRoyaltyAmount += royaltyAmounts[i];
        }

        return totalRoyaltyAmount;
    }

    // Tests

    function testFillSingleTokenBid() public {
        uint256 unitPrice = 1 ether;
        (
            Forward.Order memory order,
            bytes memory signature
        ) = generateForwardBid(alicePk, bayc, baycIdentifier, unitPrice);

        // Fill bid
        vm.startPrank(baycOwner);
        ERC721(bayc).setApprovalForAll(address(forward), true);
        forward.fillBid(
            Forward.FillDetails({
                order: order,
                signature: signature,
                fillAmount: 1
            })
        );
        vm.stopPrank();

        // Ensure the taker got the payment from the bid
        require(weth.balanceOf(baycOwner) == unitPrice);

        // Ensure the token is now inside the protocol
        require(ERC721(bayc).ownerOf(baycIdentifier) == address(forward));

        address owner = forward.erc721Owners(
            keccak256(abi.encode(bayc, baycIdentifier))
        );
        require(owner == alice);

        // Cannot fill an order for which the fillable quantity got to zero
        vm.expectRevert(Forward.InsufficientAmountAvailable.selector);
        vm.prank(baycOwner);
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
        identifiers[2] = keccak256(abi.encode(uint256(baycIdentifier)));
        identifiers[3] = keccak256(abi.encode(uint256(4)));

        uint256 criteria = uint256(merkle.getRoot(identifiers));

        uint256 identifier = baycIdentifier;
        bytes32[] memory criteriaProof = merkle.getProof(identifiers, 2);

        uint256 unitPrice = 1 ether;
        (
            Forward.Order memory order,
            bytes memory signature
        ) = generateForwardBid(alicePk, bayc, criteria, unitPrice);

        // Fill bid
        vm.startPrank(baycOwner);
        ERC721(bayc).setApprovalForAll(address(forward), true);
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
        require(weth.balanceOf(baycOwner) == unitPrice);

        // Ensure the token is now inside the protocol
        require(ERC721(bayc).ownerOf(identifier) == address(forward));

        address owner = forward.erc721Owners(
            keccak256(abi.encode(bayc, identifier))
        );
        require(owner == alice);
    }

    function testListingWithinTheProtocol() public {
        vm.prank(baycOwner);
        ERC721(bayc).transferFrom(baycOwner, bob, baycIdentifier);

        uint256 bidUnitPrice = 1 ether;
        (
            Forward.Order memory forwardOrder,
            bytes memory signature
        ) = generateForwardBid(alicePk, bayc, baycIdentifier, bidUnitPrice);

        // Fill bid
        vm.startPrank(bob);
        ERC721(bayc).setApprovalForAll(address(forward), true);
        forward.fillBid(
            Forward.FillDetails({
                order: forwardOrder,
                signature: signature,
                fillAmount: 1
            })
        );
        vm.stopPrank();

        uint256 listingPrice = 70 ether;
        ISeaport.Order memory seaportOrder = generateSeaportListing(
            alicePk,
            bayc,
            baycIdentifier,
            listingPrice
        );

        uint256 aliceETHBalanceBefore = alice.balance;

        // Fill listing
        vm.startPrank(carol);
        forward.SEAPORT().fulfillOrder{value: listingPrice}(
            seaportOrder,
            bytes32(0)
        );
        vm.stopPrank();

        uint256 aliceETHBalanceAfter = alice.balance;

        // Fetch the royalties to be paid on the listing
        uint256 totalRoyaltyAmount = getTotalRoyaltyAmount(
            bayc,
            baycIdentifier,
            listingPrice
        );

        // Ensure the taker got the payment from the listing
        require(
            aliceETHBalanceAfter - aliceETHBalanceBefore ==
                listingPrice - totalRoyaltyAmount
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
