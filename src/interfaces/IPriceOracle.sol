// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IPriceOracle {
    function getCollectionFloorPriceByToken(
        address token,
        uint256 tokenId,
        uint256 maxMessageAge,
        bytes calldata offChainData
    ) external view returns (uint256);
}
