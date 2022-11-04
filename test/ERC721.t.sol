// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";
import {Merkle} from "murky/Merkle.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {ReservoirOracle} from "oracle/ReservoirOracle.sol";

import {Blacklist} from "../src/Blacklist.sol";
import {Forward} from "../src/Forward.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {Vault} from "../src/Vault.sol";

import {IRoyaltyEngine} from "../src/interfaces/external/IRoyaltyEngine.sol";
import {ISeaport} from "../src/interfaces/external/ISeaport.sol";
import {IWETH} from "../src/interfaces/external/IWETH.sol";

contract ForwardTest is Test {
    using stdJson for string;

    Blacklist internal blacklist;
    PriceOracle internal priceOracle;
    IRoyaltyEngine internal royaltyEngine;

    Forward internal forward;

    // Setup WETH
    IWETH internal weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // Setup token with on-chain royalties
    IERC721 internal bayc =
        IERC721(0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D);
    address internal baycOwner = 0x8AD272Ac86c6C88683d9a60eb8ED57E6C304bB0C;
    uint256 internal baycIdentifier1 = 7090;
    uint256 internal baycIdentifier2 = 5977;

    // Setup wallets
    uint256 internal alicePk = uint256(0x01);
    address internal alice = vm.addr(alicePk);
    address internal bob = address(0x02);
    address internal carol = address(0x03);
    address internal dan = address(0x04);
    address internal emily = address(0x05);

    function setUp() public {
        // Need to use the latest available block in order for the oracle to work
        vm.createSelectFork("mainnet");
        vm.warp(block.timestamp + 60);

        // Setup utility contracts
        blacklist = new Blacklist();
        priceOracle = new PriceOracle(
            0x32dA57E736E05f75aa4FaE2E9Be60FD904492726
        );
        royaltyEngine = IRoyaltyEngine(
            0x0385603ab55642cb4Dd5De3aE9e306809991804f
        );

        // Setup protocol contract
        forward = new Forward(
            address(blacklist),
            address(priceOracle),
            address(royaltyEngine)
        );

        // Grant some ETH to all wallets
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(dan, 100 ether);
        vm.deal(emily, 100 ether);
    }

    // Helper methods

    function fetchOracleData(address token, uint256 identifier) internal returns (bytes memory) {
        // Fetch oracle message for the token's price
        string[] memory args = new string[](3);
        args[0] = "bash";
        args[1] = "-c";
        args[
            2
        ] = string.concat(
            "curl -s https://api.reservoir.tools/oracle/collections/floor-ask/v4?kind=spot&twapSeconds=0&token=",
            Strings.toHexString(uint256(uint160(token))),
            ":",
            Strings.toString(identifier)
        );

        // Decode the JSON response into a `Message` struct
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
        IERC721 token,
        uint256 identifierOrCriteria,
        uint256 unitPrice,
        uint128 amount
    ) internal returns (Forward.Order memory order, bytes memory signature) {
        address maker = vm.addr(makerPk);

        // Prepare balance and approval
        vm.startPrank(maker);
        weth.deposit{value: unitPrice * amount}();
        weth.approve(address(forward), unitPrice * amount);
        vm.stopPrank();

        // Generate bid
        order = Forward.Order({
            itemKind: identifierOrCriteria > 0 && identifierOrCriteria < 10000
                ? Forward.ItemKind.ERC721
                : Forward.ItemKind.ERC721_WITH_CRITERIA,
            maker: maker,
            token: address(token),
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
        address token,
        uint256 identifier,
        uint256 unitPrice
    ) internal returns (ISeaport.Order memory order) {
        address maker = vm.addr(makerPk);
        Vault vault = forward.vaults(maker);

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
        parameters.offerer = address(vault);
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
        // We encode the following in the EIP1271 signature:
        // - compacted listing data
        // - oracle data
        order.signature = abi.encode(
            Vault.SeaportListingDetails({
                itemType: ISeaport.ItemType.ERC721,
                token: token,
                identifier: identifier,
                amount: 1,
                startTime: parameters.startTime,
                endTime: parameters.endTime,
                salt: parameters.salt,
                payments: payments,
                signature: signature
            }),
            fetchOracleData(token, identifier)
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
        // Create vault
        vm.prank(alice);
        forward.createVault();

        // Construct single-token bid
        uint256 unitPrice = 1 ether;
        (
            Forward.Order memory order,
            bytes memory signature
        ) = generateForwardBid(alicePk, bayc, baycIdentifier1, unitPrice, 1);

        // Fill bid
        vm.startPrank(baycOwner);
        bayc.setApprovalForAll(address(forward), true);
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

        // Ensure the token is now inside the maker's vault
        require(
            bayc.ownerOf(baycIdentifier1) == address(forward.vaults(alice))
        );

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
        // Create vault
        vm.prank(alice);
        forward.createVault();

        bytes32[] memory identifiers = new bytes32[](4);
        identifiers[0] = keccak256(abi.encode(uint256(1)));
        identifiers[1] = keccak256(abi.encode(uint256(2)));
        identifiers[2] = keccak256(abi.encode(uint256(baycIdentifier1)));
        identifiers[3] = keccak256(abi.encode(uint256(4)));

        // Generate criteria proof
        Merkle merkle = new Merkle();
        uint256 criteria = uint256(merkle.getRoot(identifiers));
        bytes32[] memory criteriaProof = merkle.getProof(identifiers, 2);

        // Construct criteria bid
        uint256 unitPrice = 1 ether;
        (
            Forward.Order memory order,
            bytes memory signature
        ) = generateForwardBid(alicePk, bayc, criteria, unitPrice, 1);

        // Fill bid
        vm.startPrank(baycOwner);
        bayc.setApprovalForAll(address(forward), true);
        forward.fillBidWithCriteria(
            Forward.FillDetails({
                order: order,
                signature: signature,
                fillAmount: 1
            }),
            baycIdentifier1,
            criteriaProof
        );
        vm.stopPrank();

        // Ensure the taker got the payment from the bid
        require(weth.balanceOf(baycOwner) == unitPrice);

        // Ensure the token is now inside the maker's vault
        require(
            bayc.ownerOf(baycIdentifier1) == address(forward.vaults(alice))
        );
    }

    function testPartialBidFilling() external {
        // Create vault
        vm.prank(alice);
        forward.createVault();

        // Construct single-token bid
        uint256 unitPrice = 1 ether;
        (
            Forward.Order memory order,
            bytes memory signature
        ) = generateForwardBid(alicePk, bayc, 0, unitPrice, 2);

        // Fill bid
        vm.startPrank(baycOwner);
        bayc.setApprovalForAll(address(forward), true);
        forward.fillBidWithCriteria(
            Forward.FillDetails({order: order, signature: signature, fillAmount: 1}),
            baycIdentifier1,
            new bytes32[](0)
        );
        vm.stopPrank();

        // Check the order's status
        (, uint128 filledAmount) = forward.orderStatuses(
            forward.getOrderHash(order)
        );
        require(filledAmount == 1);

        // Fill bid a second time
                vm.startPrank(baycOwner);
        bayc.setApprovalForAll(address(forward), true);
        forward.fillBidWithCriteria(
            Forward.FillDetails({order: order, signature: signature, fillAmount: 1}),
            baycIdentifier2,
            new bytes32[](0)
        );
        vm.stopPrank();

        // Check the order's status
        (, filledAmount) = forward.orderStatuses(
            forward.getOrderHash(order)
        );
        require(filledAmount == 2);
    }

    // function testFillSeaportListing() public {
    //     vm.prank(tokenOwner);
    //     token.transferFrom(tokenOwner, bob, tokenIdentifier);

    //     uint256 bidUnitPrice = 1 ether;
    //     (
    //         Forward.Order memory forwardOrder,
    //         bytes memory signature
    //     ) = generateForwardBid(
    //             alicePk,
    //             token,
    //             tokenIdentifier,
    //             bidUnitPrice,
    //             1
    //         );

    //     // Fill bid
    //     vm.startPrank(bob);
    //     token.setApprovalForAll(address(forward), true);
    //     forward.fillBid(
    //         Forward.FillDetails({order: forwardOrder, signature: signature})
    //     );
    //     vm.stopPrank();

    //     uint256 listingPrice = 70 ether;
    //     ISeaport.Order memory seaportOrder = generateSeaportListing(
    //         alicePk,
    //         address(token),
    //         tokenIdentifier,
    //         listingPrice
    //     );

    //     uint256 aliceETHBalanceBefore = alice.balance;

    //     // Fill listing
    //     vm.startPrank(carol);
    //     forward.SEAPORT().fulfillOrder{value: listingPrice}(
    //         seaportOrder,
    //         bytes32(0)
    //     );
    //     vm.stopPrank();

    //     uint256 aliceETHBalanceAfter = alice.balance;

    //     // Fetch the royalties to be paid relative to the listing's price
    //     uint256 totalRoyaltyAmount = getTotalRoyaltyAmount(
    //         address(token),
    //         tokenIdentifier,
    //         listingPrice
    //     );

    //     // Ensure the taker got the payment from the listing
    //     require(
    //         aliceETHBalanceAfter - aliceETHBalanceBefore ==
    //             listingPrice - totalRoyaltyAmount
    //     );
    // }

    // function testCounterIncrement() public {
    //     vm.prank(tokenOwner);
    //     token.transferFrom(tokenOwner, bob, tokenIdentifier);

    //     uint256 bidUnitPrice = 1 ether;
    //     (
    //         Forward.Order memory forwardOrder,
    //         bytes memory signature
    //     ) = generateForwardBid(
    //             alicePk,
    //             token,
    //             tokenIdentifier,
    //             bidUnitPrice,
    //             1
    //         );

    //     vm.prank(alice);
    //     forward.incrementCounter();

    //     // Incrementing the counter invalidates any previously signed orders
    //     vm.startPrank(bob);
    //     token.setApprovalForAll(address(forward), true);
    //     vm.expectRevert(Forward.InvalidSignature.selector);
    //     forward.fillBid(
    //         Forward.FillDetails({order: forwardOrder, signature: signature})
    //     );
    //     vm.stopPrank();
    // }

    // function testCancel() external {
    //     vm.prank(tokenOwner);
    //     token.transferFrom(tokenOwner, bob, tokenIdentifier);

    //     uint256 bidUnitPrice = 1 ether;
    //     (
    //         Forward.Order memory forwardOrder,
    //         bytes memory signature
    //     ) = generateForwardBid(
    //             alicePk,
    //             token,
    //             tokenIdentifier,
    //             bidUnitPrice,
    //             1
    //         );

    //     Forward.Order[] memory ordersToCancel = new Forward.Order[](1);
    //     ordersToCancel[0] = forwardOrder;

    //     vm.prank(alice);
    //     forward.cancel(ordersToCancel);

    //     // Cannot fill cancelled orders
    //     vm.startPrank(bob);
    //     token.setApprovalForAll(address(forward), true);
    //     vm.expectRevert(Forward.OrderIsCancelled.selector);
    //     forward.fillBid(
    //         Forward.FillDetails({order: forwardOrder, signature: signature})
    //     );
    //     vm.stopPrank();
    // }

    // function testDepositAndWithdraw() external {
    //     Forward.Item[] memory items = new Forward.Item[](1);
    //     items[0] = Forward.Item({token: token, identifier: tokenIdentifier});

    //     // Deposit
    //     vm.startPrank(tokenOwner);
    //     token.setApprovalForAll(address(forward), true);
    //     forward.deposit(items);
    //     vm.stopPrank();

    //     // Ensure the item is owned by the depositor within the protocol
    //     require(token.ownerOf(tokenIdentifier) == address(forward));
    //     require(
    //         forward.itemOwners(keccak256(abi.encode(token, tokenIdentifier))) ==
    //             tokenOwner
    //     );

    //     bytes[] memory data = new bytes[](1);
    //     data[0] = fetchOracleOffChainData();

    //     // Must pay royalties when withdrawing
    //     vm.startPrank(tokenOwner);
    //     vm.expectRevert(Forward.PaymentFailed.selector);
    //     forward.withdraw(items, data, tokenOwner);
    //     vm.stopPrank();

    //     uint256 price = priceOracle.getPrice(
    //         address(token),
    //         tokenIdentifier,
    //         1 minutes,
    //         data[0]
    //     );

    //     // Fetch the royalties to be paid relative to the token's price
    //     uint256 totalRoyaltyAmount = getTotalRoyaltyAmount(
    //         address(token),
    //         tokenIdentifier,
    //         price
    //     );

    //     // Withdraw
    //     vm.startPrank(tokenOwner);
    //     forward.withdraw{value: totalRoyaltyAmount}(items, data, tokenOwner);
    //     vm.stopPrank();

    //     // Ensure the token is now in the withdrawer's wallet
    //     require(token.ownerOf(tokenIdentifier) == tokenOwner);
    // }

    // function testBlacklist() external {
    //     // Blacklist
    //     vm.prank(blacklist.owner());
    //     blacklist.adminSetBlacklistStatus(address(token), true);

    //     Forward.Item[] memory items = new Forward.Item[](1);
    //     items[0] = Forward.Item({token: token, identifier: tokenIdentifier});

    //     // Deposit will fail if the token is blacklisted
    //     vm.startPrank(tokenOwner);
    //     token.setApprovalForAll(address(forward), true);
    //     vm.expectRevert(Forward.Blacklisted.selector);
    //     forward.deposit(items);
    //     vm.stopPrank();
    // }

    // function testMigrate() external {
    //     Forward.Item[] memory items = new Forward.Item[](1);
    //     items[0] = Forward.Item({token: token, identifier: tokenIdentifier});

    //     // Deposit
    //     vm.startPrank(tokenOwner);
    //     token.setApprovalForAll(address(forward), true);
    //     forward.deposit(items);
    //     vm.stopPrank();

    //     IMigrateTo migrateTo = new DummyMigrateTo(address(forward));

    //     // Only the protocol should be able to trigger migrations
    //     vm.prank(tokenOwner);
    //     vm.expectRevert(DummyMigrateTo.Unauthorized.selector);
    //     migrateTo.processMigratedItem(token, tokenIdentifier, tokenOwner);

    //     // Start migration
    //     vm.prank(forward.owner());
    //     forward.updateMigrateTo(address(migrateTo));

    //     // Migrate
    //     vm.prank(tokenOwner);
    //     forward.migrate(items);

    //     // Ensure the item was migrate successfully
    //     require(token.ownerOf(tokenIdentifier) == address(migrateTo));
    //     require(
    //         forward.itemOwners(keccak256(abi.encode(token, tokenIdentifier))) ==
    //             address(0)
    //     );

    //     // Migrating a second time will fail
    //     vm.prank(tokenOwner);
    //     vm.expectRevert(Forward.Unauthorized.selector);
    //     forward.migrate(items);
    // }
}
