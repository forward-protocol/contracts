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

    function fetchOracleOffChainData() internal returns (bytes memory) {
        // Fetch oracle message for the token's collection floor price
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

        return abi.encode(message);
    }

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

    function generateForwardListing(
        uint256 makerPk,
        address token,
        uint256 identifier,
        uint256 unitPrice
    ) internal returns (Forward.Order memory order, bytes memory signature) {
        address maker = vm.addr(makerPk);

        // Generate listing
        order = Forward.Order({
            orderKind: Forward.OrderKind.LISTING,
            itemKind: Forward.ItemKind.ERC721,
            maker: maker,
            token: token,
            identifierOrCriteria: identifier,
            unitPrice: unitPrice,
            amount: 1,
            salt: 0,
            expiration: block.timestamp + 1
        });

        // Sign listing
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

        order.parameters = parameters;
        // We encode the following in the EIP1271 signature:
        // - compacted listing data
        // - actual order signature
        // - oracle pricing message
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
            fetchOracleOffChainData()
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
            baycIdentifier,
            criteriaProof
        );
        vm.stopPrank();

        // Ensure the taker got the payment from the bid
        require(weth.balanceOf(baycOwner) == unitPrice);

        // Ensure the token is now inside the protocol
        require(ERC721(bayc).ownerOf(baycIdentifier) == address(forward));

        // Ensure the owner is owned by the maker inside the protocol
        address owner = forward.erc721Owners(
            keccak256(abi.encode(bayc, baycIdentifier))
        );
        require(owner == alice);
    }

    function testFillInternalListing() public {
        vm.prank(baycOwner);
        ERC721(bayc).transferFrom(baycOwner, bob, baycIdentifier);

        uint256 bidUnitPrice = 1 ether;
        (
            Forward.Order memory bid,
            bytes memory bidSignature
        ) = generateForwardBid(alicePk, bayc, baycIdentifier, bidUnitPrice);

        // Fill bid
        vm.startPrank(bob);
        ERC721(bayc).setApprovalForAll(address(forward), true);
        forward.fillBid(
            Forward.FillDetails({
                order: bid,
                signature: bidSignature,
                fillAmount: 1
            })
        );
        vm.stopPrank();

        uint256 listingUnitPrice = 1.5 ether;
        (
            Forward.Order memory listing,
            bytes memory listingSignature
        ) = generateForwardListing(
                alicePk,
                bayc,
                baycIdentifier,
                listingUnitPrice
            );

        uint256 aliceETHBalanceBefore = alice.balance;

        // Fill listing
        vm.startPrank(carol);
        forward.fillListing{value: listingUnitPrice}(
            Forward.FillDetails({
                order: listing,
                signature: listingSignature,
                fillAmount: 1
            })
        );
        vm.stopPrank();

        uint256 aliceETHBalanceAfter = alice.balance;

        // Ensure the maker got the payment from the listing
        require(
            aliceETHBalanceAfter - aliceETHBalanceBefore == listingUnitPrice
        );

        // Ensure the token is still inside the protocol
        require(ERC721(bayc).ownerOf(baycIdentifier) == address(forward));

        // Ensure the owner is owned by the taker inside the protocol
        address owner = forward.erc721Owners(
            keccak256(abi.encode(bayc, baycIdentifier))
        );
        require(owner == carol);
    }

    function testFillExternalListing() public {
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

        // Fetch the royalties to be paid relative to the listing's price
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

    function testCounterIncrement() public {
        vm.prank(baycOwner);
        ERC721(bayc).transferFrom(baycOwner, bob, baycIdentifier);

        uint256 bidUnitPrice = 1 ether;
        (
            Forward.Order memory forwardOrder,
            bytes memory signature
        ) = generateForwardBid(alicePk, bayc, baycIdentifier, bidUnitPrice);

        vm.prank(alice);
        forward.incrementCounter();

        // Incrementing the counter invalidates any previously signed orders
        vm.startPrank(bob);
        ERC721(bayc).setApprovalForAll(address(forward), true);
        vm.expectRevert(Forward.InvalidSignature.selector);
        forward.fillBid(
            Forward.FillDetails({
                order: forwardOrder,
                signature: signature,
                fillAmount: 1
            })
        );
        vm.stopPrank();
    }

    function testWithdraw() external {
        Forward.ERC721Item[] memory items = new Forward.ERC721Item[](1);
        items[0] = Forward.ERC721Item({
            token: ERC721(bayc),
            identifier: baycIdentifier
        });

        // Deposit
        vm.startPrank(baycOwner);
        ERC721(bayc).setApprovalForAll(address(forward), true);
        forward.depositERC721s(items);
        vm.stopPrank();

        bytes[] memory data = new bytes[](1);
        data[0] = fetchOracleOffChainData();

        // Must pay royalties when withdrawing
        vm.startPrank(baycOwner);
        vm.expectRevert(Forward.PaymentFailed.selector);
        forward.withdrawERC721s(items, data, baycOwner);
        vm.stopPrank();

        uint256 floorPrice = oracle.getCollectionFloorPriceByToken(
            bayc,
            baycIdentifier,
            1 minutes,
            data[0]
        );

        // Fetch the royalties to be paid relative to the collection's floor price
        uint256 totalRoyaltyAmount = getTotalRoyaltyAmount(
            bayc,
            baycIdentifier,
            floorPrice
        );

        // Withdraw
        vm.startPrank(baycOwner);
        forward.withdrawERC721s{value: totalRoyaltyAmount}(
            items,
            data,
            baycOwner
        );
        vm.stopPrank();

        // Ensure the token is now in the withdrawer's wallet
        require(ERC721(bayc).ownerOf(baycIdentifier) == baycOwner);
    }
}
