// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IPriceOracle {
    function getCollectionFloorPriceByToken(
        address token,
        uint256 tokenId,
        address currency
    ) external view returns (uint256 price);
}
