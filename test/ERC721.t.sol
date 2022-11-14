// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";
import {Merkle} from "murky/Merkle.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {ReservoirOracle} from "oracle/ReservoirOracle.sol";

import {OptOutList} from "../src/OptOutList.sol";
import {Forward} from "../src/Forward.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {Vault} from "../src/Vault.sol";

import {IRoyaltyEngine} from "../src/interfaces/external/IRoyaltyEngine.sol";
import {ISeaport} from "../src/interfaces/external/ISeaport.sol";
import {IWETH} from "../src/interfaces/external/IWETH.sol";

contract ForwardTest is Test {
    using stdJson for string;

    Forward internal forward;

    // Setup WETH
    IWETH internal weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // Setup token with on-chain royalties
    IERC721 internal bayc = IERC721(0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D);
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
        address optOutList = address(new OptOutList());
        address priceOracle = address(
            new PriceOracle(0x32dA57E736E05f75aa4FaE2E9Be60FD904492726)
        );
        address royaltyEngine = 0x0385603ab55642cb4Dd5De3aE9e306809991804f;

        // Setup protocol contract
        forward = new Forward(optOutList, priceOracle, royaltyEngine);

        // Grant some ETH to all wallets
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(dan, 100 ether);
        vm.deal(emily, 100 ether);
    }

    // Helper methods

    function fetchOracleData(address token, uint256 identifier)
        internal
        returns (bytes memory)
    {
        // Fetch oracle message for the token's price
        string[] memory args = new string[](3);
        args[0] = "bash";
        args[1] = "-c";
        args[2] = string.concat(
            "curl -s https://api.reservoir.tools/oracle/collections/floor-ask/v4?token=",
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
        uint256 unitPrice,
        // Additional payments on top of the royalties should be supported
        // without any issues by the vault EIP1271 signature verification
        Vault.Payment[] memory additionalPayments
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

        uint256 additionalPaymentsLength = additionalPayments.length;
        uint256 royaltiesLength = royaltyRecipients.length;
        uint256 considerationCount = 1 +
            additionalPaymentsLength +
            royaltiesLength;

        // Compute the total royalty amount (including additional payments)
        uint256 totalRoyaltyAmount;
        for (uint256 i = 0; i < additionalPaymentsLength; i++) {
            totalRoyaltyAmount += additionalPayments[i].amount;
        }
        for (uint256 i = 0; i < royaltiesLength; i++) {
            totalRoyaltyAmount += royaltyAmounts[i];
        }

        // Create Seaport listing
        ISeaport.OrderParameters memory parameters;
        parameters.offerer = address(vault);
        // parameters.zone = address(0);
        parameters.offer = new ISeaport.OfferItem[](1);
        parameters.consideration = new ISeaport.ConsiderationItem[](
            considerationCount
        );
        parameters.orderType = ISeaport.OrderType.PARTIAL_OPEN;
        parameters.startTime = block.timestamp;
        parameters.endTime = block.timestamp + 1;
        // parameters.zoneHash = bytes32(0);
        // parameters.salt = 0;
        parameters.conduitKey = forward.seaportConduitKey();
        parameters.totalOriginalConsiderationItems = considerationCount;

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
            address(vault)
        );
        for (uint256 i = 0; i < additionalPaymentsLength; i++) {
            parameters.consideration[i + 1] = ISeaport.ConsiderationItem(
                ISeaport.ItemType.NATIVE,
                address(0),
                0,
                additionalPayments[i].amount,
                additionalPayments[i].amount,
                additionalPayments[i].recipient
            );
        }
        for (uint256 i = 0; i < royaltiesLength; i++) {
            parameters.consideration[
                i + 1 + additionalPaymentsLength
            ] = ISeaport.ConsiderationItem(
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

    function testPartiallyFillBid() external {
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
            Forward.FillDetails({
                order: order,
                signature: signature,
                fillAmount: 1
            }),
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
            Forward.FillDetails({
                order: order,
                signature: signature,
                fillAmount: 1
            }),
            baycIdentifier2,
            new bytes32[](0)
        );
        vm.stopPrank();

        // Check the order's status
        (, filledAmount) = forward.orderStatuses(forward.getOrderHash(order));
        require(filledAmount == 2);
    }

    function testFillSeaportListing() public {
        // Create vault
        vm.prank(alice);
        Vault vault = forward.createVault();

        // Deposit token to vault
        vm.prank(baycOwner);
        bayc.safeTransferFrom(baycOwner, address(vault), baycIdentifier1);

        // Include some additional payments
        Vault.Payment[] memory additionalPayments = new Vault.Payment[](2);
        additionalPayments[0] = Vault.Payment({
            amount: 0.01 ether,
            recipient: dan
        });
        additionalPayments[1] = Vault.Payment({
            amount: 0.0045 ether,
            recipient: emily
        });

        // Construct Seaport listing
        uint256 listingPrice = 70 ether;
        ISeaport.Order memory seaportOrder = generateSeaportListing(
            alicePk,
            address(bayc),
            baycIdentifier1,
            listingPrice,
            additionalPayments
        );

        // Save the maker's balance before filling
        uint256 aliceETHBalanceBefore = alice.balance;

        // Fill listing
        vm.startPrank(carol);
        vault.SEAPORT().fulfillOrder{value: listingPrice}(
            seaportOrder,
            bytes32(0)
        );
        vm.stopPrank();

        // Save the maker's balance after filling
        uint256 aliceETHBalanceAfter = alice.balance;

        // Fetch the royalties to be paid relative to the listing's price
        uint256 totalRoyaltyAmount = getTotalRoyaltyAmount(
            address(bayc),
            baycIdentifier1,
            listingPrice
        );

        uint256 totalAdditionalAmount;
        for (uint256 i = 0; i < additionalPayments.length; i++) {
            totalAdditionalAmount += additionalPayments[i].amount;
        }

        // Ensure the maker got the payment from the listing
        require(
            aliceETHBalanceAfter - aliceETHBalanceBefore ==
                listingPrice - totalRoyaltyAmount - totalAdditionalAmount
        );
    }

    function testIncrementCounter() public {
        // Create vault
        vm.prank(alice);
        forward.createVault();

        // Create single-token bid
        uint256 bidUnitPrice = 1 ether;
        (
            Forward.Order memory forwardOrder,
            bytes memory signature
        ) = generateForwardBid(alicePk, bayc, baycIdentifier1, bidUnitPrice, 1);

        // Increment counter
        vm.prank(alice);
        forward.incrementCounter();

        // Orders signed with an old counter got invalidated
        vm.startPrank(baycOwner);
        bayc.setApprovalForAll(address(forward), true);
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
        // Create vault
        vm.prank(alice);
        forward.createVault();

        // Create single-token bid
        uint256 bidUnitPrice = 1 ether;
        (
            Forward.Order memory forwardOrder,
            bytes memory signature
        ) = generateForwardBid(alicePk, bayc, baycIdentifier1, bidUnitPrice, 1);

        // Prepare orders to cancel
        Forward.Order[] memory ordersToCancel = new Forward.Order[](1);
        ordersToCancel[0] = forwardOrder;

        // Cancel
        vm.prank(alice);
        forward.cancel(ordersToCancel);

        // Cannot fill cancelled orders
        vm.startPrank(baycOwner);
        bayc.setApprovalForAll(address(forward), true);
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

    function testDeposit() external {
        // Create vault
        vm.prank(alice);
        Vault vault = forward.createVault();

        // Deposit token to vault
        vm.prank(baycOwner);
        bayc.safeTransferFrom(baycOwner, address(vault), baycIdentifier1);

        // Prepare withdraw data
        Vault.ERC721Item[] memory items = new Vault.ERC721Item[](1);
        items[0] = Vault.ERC721Item(bayc, baycIdentifier1);
        bytes[] memory data = new bytes[](1);
        data[0] = fetchOracleData(address(bayc), baycIdentifier1);

        // When withdrawing, royalties must be paid
        vm.startPrank(alice);
        vm.expectRevert(Vault.UnsuccessfulPayment.selector);
        vault.withdrawERC721s(items, data, alice);
        vm.stopPrank();

        // Extract the price from the oracle message
        uint256 price = forward.priceOracle().getPrice(
            address(bayc),
            baycIdentifier1,
            1 minutes,
            data[0]
        );

        // Compute the royalties to be paid relative to the token's price
        uint256 totalRoyaltyAmount = getTotalRoyaltyAmount(
            address(bayc),
            baycIdentifier1,
            price
        );

        // Withdraw
        vm.startPrank(alice);
        vault.withdrawERC721s{value: totalRoyaltyAmount}(items, data, alice);
        vm.stopPrank();

        // Ensure the token was successfully withdrawn
        require(bayc.ownerOf(baycIdentifier1) == alice);
    }

    function testOptOutList() external {
        // Create vault
        vm.prank(baycOwner);
        Vault vault = forward.createVault();

        OptOutList optOutList = OptOutList(address(forward.optOutList()));

        // Mark collection as opted-out
        vm.prank(optOutList.owner());
        optOutList.adminSetOptOutStatus(address(bayc), true);

        // Depositing will fail if the token's collection is opted-out of Forward
        vm.startPrank(baycOwner);
        vm.expectRevert(Vault.CollectionOptedOut.selector);
        bayc.safeTransferFrom(baycOwner, address(vault), baycIdentifier1);
        vm.stopPrank();
    }
}
