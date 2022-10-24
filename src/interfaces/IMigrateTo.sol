// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IERC1155} from "openzeppelin/token/ERC1155/IERC1155.sol";

interface IMigrateTo {
    function processMigratedERC721(
        IERC721 token,
        uint256 identifier,
        address owner
    ) external;

    function processMigratedERC1155(
        IERC1155 token,
        uint256 id,
        uint256 amount,
        address owner
    ) external;
}
