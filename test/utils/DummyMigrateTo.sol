// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";

import {IMigrateTo} from "../../src/interfaces/IMigrateTo.sol";

contract DummyMigrateTo is IMigrateTo {
    error Unauthorized();

    address public migrateFrom;

    constructor(address _migrateFrom) {
        migrateFrom = _migrateFrom;
    }

    function processMigratedItem(
        IERC721, // token
        uint256, // identifier
        address // owner
    ) external view override {
        if (msg.sender != migrateFrom) {
            revert Unauthorized();
        }
    }

    function onERC721Received(
        address, // operator
        address, // from
        uint256, // tokenId
        bytes calldata // data
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
