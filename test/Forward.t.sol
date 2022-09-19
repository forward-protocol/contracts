// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";

import {Forward} from "../src/Forward.sol";
import {Vault} from "../src/Vault.sol";
import {ISeaport} from "../src/interfaces/ISeaport.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
}

contract MockNFT is ERC721 {
    address public creator;

    constructor(address _creator) ERC721("MockNFT", "MOCK") {
        creator = _creator;
    }

    function mint(uint256 tokenId) external {
        _mint(msg.sender, tokenId);
    }

    // --- EIP2981 ---

    function royaltyInfo(uint256, uint256 price)
        external
        view
        returns (address receiver, uint256 amount)
    {
        receiver = creator;
        amount = (price * 500) / 10000;
    }
}

contract ForwardTest is Test {
    Forward internal forward;
    MockNFT internal nft;

    IWETH internal WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ISeaport public constant SEAPORT =
        ISeaport(0x00000000006c3852cbEf3e08E8dF289169EdE581);

    uint256 internal alicePk = uint256(0x01);
    address internal alice;
    address internal bob = address(0x02);
    address internal carol = address(0x03);
    address internal marketplace = address(0x04);
    address internal creator = address(0x05);

    function setUp() public {
        alice = vm.addr(alicePk);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);

        forward = new Forward();
        nft = new MockNFT(creator);
    }

    function testFill() public {
        uint256 tokenId = 1;
        uint256 bidPrice = 1 ether;

        vm.prank(bob);
        nft.mint(tokenId);

        vm.prank(alice);
        WETH.deposit{value: bidPrice}();

        vm.prank(alice);
        Vault vault = forward.createVault();

        Forward.Bid memory bid = Forward.Bid(
            alice,
            nft,
            tokenId,
            bidPrice,
            block.timestamp
        );

        vm.prank(alice);
        WETH.approve(address(forward), type(uint256).max);

        vm.prank(alice);
        uint256 bidId = forward.createBid(bid);

        vm.prank(bob);
        nft.setApprovalForAll(address(forward), true);

        vm.prank(bob);
        forward.acceptBid(bidId);

        require(WETH.balanceOf(bob) == (bidPrice * 9500) / 10000);
        require(WETH.balanceOf(address(vault)) == (bidPrice * 500) / 10000);

        ISeaport.OrderParameters memory parameters;
        parameters.offerer = address(vault);
        // parameters.zone = address(0);
        parameters.offer = new ISeaport.OfferItem[](1);
        parameters.consideration = new ISeaport.ConsiderationItem[](3);
        // parameters.orderType = ISeaport.OrderType.FULL_OPEN;
        parameters.startTime = block.timestamp - 60;
        parameters.endTime = block.timestamp + 60;
        // parameters.zoneHash = bytes32(0);
        // parameters.salt = 0;
        // parameters.conduitKey = bytes32(0);
        parameters.totalOriginalConsiderationItems = 3;

        uint256 listingPrice = 1.2 ether;

        parameters.offer[0] = ISeaport.OfferItem(
            ISeaport.ItemType.ERC721,
            address(nft),
            tokenId,
            1,
            1
        );
        parameters.consideration[0] = ISeaport.ConsiderationItem(
            ISeaport.ItemType.NATIVE,
            address(0),
            0,
            (listingPrice * 9300) / 10000,
            (listingPrice * 9300) / 10000,
            address(0)
        );
        parameters.consideration[1] = ISeaport.ConsiderationItem(
            ISeaport.ItemType.NATIVE,
            address(0),
            0,
            (listingPrice * 200) / 10000,
            (listingPrice * 200) / 10000,
            marketplace
        );
        parameters.consideration[2] = ISeaport.ConsiderationItem(
            ISeaport.ItemType.NATIVE,
            address(0),
            0,
            (listingPrice * 500) / 10000,
            (listingPrice * 500) / 10000,
            creator
        );

        bytes memory signature;
        {
            ISeaport.OrderComponents memory components = ISeaport
                .OrderComponents(
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
                        "\x19\x01",
                        bytes32(
                            0xb50c8913581289bd2e066aeef89fceb9615d490d673131fd1a7047436706834e
                        ),
                        SEAPORT.getOrderHash(components)
                    )
                )
            );
            signature = abi.encodePacked(r, s, v);
        }

        ISeaport.Order memory order;
        order.parameters = parameters;
        order.signature = abi.encode(
            address(nft),
            tokenId,
            parameters.startTime,
            parameters.endTime,
            parameters.salt,
            parameters.consideration,
            signature
        );

        vm.prank(carol);
        SEAPORT.fulfillOrder{value: listingPrice}(order, bytes32(0));
    }
}
