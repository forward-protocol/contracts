// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";
import {Merkle} from "murky/Merkle.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {ReservoirOracle} from "oracle/ReservoirOracle.sol";

import {Blacklist} from "../src/Blacklist.sol";
import {Forward} from "../src/Forward.sol";
import {PriceOracle} from "../src/PriceOracle.sol";

import {IRoyaltyEngine} from "../src/interfaces/external/IRoyaltyEngine.sol";
import {ISeaport} from "../src/interfaces/external/ISeaport.sol";
import {IWETH} from "../src/interfaces/external/IWETH.sol";

contract ERC721Test is Test {
    using stdJson for string;

    Blacklist internal blacklist;
    PriceOracle internal priceOracle;
    IRoyaltyEngine internal royaltyEngine;

    Forward internal forward;
    IWETH internal weth;

    // Setup token with on-chain royalties
    address internal token = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D;
    address internal tokenOwner = 0x8AD272Ac86c6C88683d9a60eb8ED57E6C304bB0C;
    uint256 internal tokenIdentifier = 7090;

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

        blacklist = new Blacklist();
        priceOracle = new PriceOracle(
            0x32dA57E736E05f75aa4FaE2E9Be60FD904492726
        );
        royaltyEngine = IRoyaltyEngine(
            0x0385603ab55642cb4Dd5De3aE9e306809991804f
        );

        forward = new Forward(
            address(blacklist),
            address(priceOracle),
            address(royaltyEngine)
        );
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
        // Fetch oracle message for the token's price
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
        address tokenAddress,
        uint256 identifierOrCriteria,
        uint256 unitPrice,
        uint128 amount
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
            itemKind: identifierOrCriteria > 0 && identifierOrCriteria < 10000
                ? Forward.ItemKind.ERC721
                : Forward.ItemKind.ERC721_CRITERIA_OR_EXTERNAL,
            maker: maker,
            token: tokenAddress,
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

    function generateForwardInternalListing(
        uint256 makerPk,
        address tokenAddress,
        uint256 identifier,
        uint256 unitPrice
    ) internal returns (Forward.Order memory order, bytes memory signature) {
        address maker = vm.addr(makerPk);

        // Generate listing
        order = Forward.Order({
            orderKind: Forward.OrderKind.LISTING,
            itemKind: Forward.ItemKind.ERC721,
            maker: maker,
            token: tokenAddress,
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

    function generateForwardExternalListing(
        uint256 makerPk,
        address tokenAddress,
        uint256 identifier,
        uint256 unitPrice
    ) internal returns (Forward.Order memory order, bytes memory signature) {
        address maker = vm.addr(makerPk);

        // Approve the exchange
        vm.startPrank(maker);
        ERC721(tokenAddress).setApprovalForAll(address(forward), true);
        vm.stopPrank();

        // Generate listing
        order = Forward.Order({
            orderKind: Forward.OrderKind.LISTING,
            itemKind: Forward.ItemKind.ERC721_CRITERIA_OR_EXTERNAL,
            maker: maker,
            token: tokenAddress,
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
        address tokenAddress,
        uint256 identifier,
        uint256 unitPrice
    ) internal returns (ISeaport.Order memory order) {
        address maker = vm.addr(makerPk);

        // Fetch the item's royalties
        (
            address[] memory royaltyRecipients,
            uint256[] memory royaltyAmounts
        ) = forward.royaltyEngine().getRoyaltyView(
                tokenAddress,
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
            tokenAddress,
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
                token: tokenAddress,
                identifier: identifier,
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
        address tokenAddress,
        uint256 identifier,
        uint256 price
    ) internal view returns (uint256) {
        (, uint256[] memory royaltyAmounts) = forward
            .royaltyEngine()
            .getRoyaltyView(tokenAddress, identifier, price);

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
        ) = generateForwardBid(alicePk, token, tokenIdentifier, unitPrice, 1);

        // Fill bid
        vm.startPrank(tokenOwner);
        ERC721(token).setApprovalForAll(address(forward), true);
        forward.fillBid(
            Forward.FillDetails({
                order: order,
                signature: signature,
                fillAmount: 1
            })
        );
        vm.stopPrank();

        // Ensure the taker got the payment from the bid
        require(weth.balanceOf(tokenOwner) == unitPrice);

        // Ensure the token is now inside the protocol
        require(ERC721(token).ownerOf(tokenIdentifier) == address(forward));

        address owner = forward.erc721Owners(
            keccak256(abi.encode(token, tokenIdentifier))
        );
        require(owner == alice);

        // Cannot fill an order for which the fillable quantity got to zero
        vm.expectRevert(Forward.InsufficientAmountAvailable.selector);
        vm.prank(tokenOwner);
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
        identifiers[2] = keccak256(abi.encode(uint256(tokenIdentifier)));
        identifiers[3] = keccak256(abi.encode(uint256(4)));

        uint256 criteria = uint256(merkle.getRoot(identifiers));

        bytes32[] memory criteriaProof = merkle.getProof(identifiers, 2);

        uint256 unitPrice = 1 ether;
        (
            Forward.Order memory order,
            bytes memory signature
        ) = generateForwardBid(alicePk, token, criteria, unitPrice, 1);

        // Fill bid
        vm.startPrank(tokenOwner);
        ERC721(token).setApprovalForAll(address(forward), true);
        forward.fillBidWithCriteria(
            Forward.FillDetails({
                order: order,
                signature: signature,
                fillAmount: 1
            }),
            tokenIdentifier,
            criteriaProof
        );
        vm.stopPrank();

        // Ensure the taker got the payment from the bid
        require(weth.balanceOf(tokenOwner) == unitPrice);

        // Ensure the token is now inside the protocol
        require(ERC721(token).ownerOf(tokenIdentifier) == address(forward));

        // Ensure the owner is owned by the maker inside the protocol
        address owner = forward.erc721Owners(
            keccak256(abi.encode(token, tokenIdentifier))
        );
        require(owner == alice);
    }

    function testPartialBidFilling() external {
        uint256 unitPrice = 1 ether;
        (
            Forward.Order memory order,
            bytes memory signature
        ) = generateForwardBid(alicePk, token, 0, unitPrice, 1);

        // Fill bid
        vm.startPrank(tokenOwner);
        ERC721(token).setApprovalForAll(address(forward), true);
        forward.fillBidWithCriteria(
            Forward.FillDetails({
                order: order,
                signature: signature,
                fillAmount: 1
            }),
            tokenIdentifier,
            new bytes32[](0)
        );
        vm.stopPrank();

        // Check the order's status
        (, uint128 filledAmount) = forward.orderStatuses(
            forward.getOrderHash(order)
        );
        require(filledAmount == 1);

        // Filling will fail if the order is already filled
        vm.startPrank(tokenOwner);
        vm.expectRevert(Forward.InsufficientAmountAvailable.selector);
        forward.fillBidWithCriteria(
            Forward.FillDetails({
                order: order,
                signature: signature,
                fillAmount: 1
            }),
            tokenIdentifier,
            new bytes32[](0)
        );
        vm.stopPrank();
    }

    function testFillForwardInternalListing() public {
        vm.prank(tokenOwner);
        ERC721(token).transferFrom(tokenOwner, bob, tokenIdentifier);

        uint256 bidUnitPrice = 1 ether;
        (
            Forward.Order memory bid,
            bytes memory bidSignature
        ) = generateForwardBid(
                alicePk,
                token,
                tokenIdentifier,
                bidUnitPrice,
                1
            );

        // Fill bid
        vm.startPrank(bob);
        ERC721(token).setApprovalForAll(address(forward), true);
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
        ) = generateForwardInternalListing(
                alicePk,
                token,
                tokenIdentifier,
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
        require(ERC721(token).ownerOf(tokenIdentifier) == address(forward));

        // Ensure the owner is owned by the taker inside the protocol
        address owner = forward.erc721Owners(
            keccak256(abi.encode(token, tokenIdentifier))
        );
        require(owner == carol);
    }

    function testFillForwardExternalListing() public {
        vm.prank(tokenOwner);
        ERC721(token).transferFrom(tokenOwner, alice, tokenIdentifier);

        uint256 listingUnitPrice = 1.5 ether;
        (
            Forward.Order memory listing,
            bytes memory listingSignature
        ) = generateForwardExternalListing(
                alicePk,
                token,
                tokenIdentifier,
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

        // Ensure the token is now inside the protocol
        require(ERC721(token).ownerOf(tokenIdentifier) == address(forward));

        // Ensure the token is owned by the taker inside the protocol
        address owner = forward.erc721Owners(
            keccak256(abi.encode(token, tokenIdentifier))
        );
        require(owner == carol);
    }

    function testFillSeaportListing() public {
        vm.prank(tokenOwner);
        ERC721(token).transferFrom(tokenOwner, bob, tokenIdentifier);

        uint256 bidUnitPrice = 1 ether;
        (
            Forward.Order memory forwardOrder,
            bytes memory signature
        ) = generateForwardBid(
                alicePk,
                token,
                tokenIdentifier,
                bidUnitPrice,
                1
            );

        // Fill bid
        vm.startPrank(bob);
        ERC721(token).setApprovalForAll(address(forward), true);
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
            token,
            tokenIdentifier,
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
            token,
            tokenIdentifier,
            listingPrice
        );

        // Ensure the taker got the payment from the listing
        require(
            aliceETHBalanceAfter - aliceETHBalanceBefore ==
                listingPrice - totalRoyaltyAmount
        );
    }

    function testCounterIncrement() public {
        vm.prank(tokenOwner);
        ERC721(token).transferFrom(tokenOwner, bob, tokenIdentifier);

        uint256 bidUnitPrice = 1 ether;
        (
            Forward.Order memory forwardOrder,
            bytes memory signature
        ) = generateForwardBid(
                alicePk,
                token,
                tokenIdentifier,
                bidUnitPrice,
                1
            );

        vm.prank(alice);
        forward.incrementCounter();

        // Incrementing the counter invalidates any previously signed orders
        vm.startPrank(bob);
        ERC721(token).setApprovalForAll(address(forward), true);
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

    function testCancel() external {
        vm.prank(tokenOwner);
        ERC721(token).transferFrom(tokenOwner, bob, tokenIdentifier);

        uint256 bidUnitPrice = 1 ether;
        (
            Forward.Order memory forwardOrder,
            bytes memory signature
        ) = generateForwardBid(
                alicePk,
                token,
                tokenIdentifier,
                bidUnitPrice,
                1
            );

        Forward.Order[] memory ordersToCancel = new Forward.Order[](1);
        ordersToCancel[0] = forwardOrder;

        vm.prank(alice);
        forward.cancel(ordersToCancel);

        // Cannot fill cancelled orders
        vm.startPrank(bob);
        ERC721(token).setApprovalForAll(address(forward), true);
        vm.expectRevert(Forward.OrderIsCancelled.selector);
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
            token: ERC721(token),
            identifier: tokenIdentifier
        });

        // Deposit
        vm.startPrank(tokenOwner);
        ERC721(token).setApprovalForAll(address(forward), true);
        forward.depositERC721s(items);
        vm.stopPrank();

        bytes[] memory data = new bytes[](1);
        data[0] = fetchOracleOffChainData();

        // Must pay royalties when withdrawing
        vm.startPrank(tokenOwner);
        vm.expectRevert(Forward.PaymentFailed.selector);
        forward.withdrawERC721s(items, data, tokenOwner);
        vm.stopPrank();

        uint256 floorPrice = priceOracle.getPrice(
            token,
            tokenIdentifier,
            1 minutes,
            data[0]
        );

        // Fetch the royalties to be paid relative to the collection's floor price
        uint256 totalRoyaltyAmount = getTotalRoyaltyAmount(
            token,
            tokenIdentifier,
            floorPrice
        );

        // Withdraw
        vm.startPrank(tokenOwner);
        forward.withdrawERC721s{value: totalRoyaltyAmount}(
            items,
            data,
            tokenOwner
        );
        vm.stopPrank();

        // Ensure the token is now in the withdrawer's wallet
        require(ERC721(token).ownerOf(tokenIdentifier) == tokenOwner);
    }
}
