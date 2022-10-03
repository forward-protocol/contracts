// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IVault {
    function unlockERC721(address token, uint256 identifier) external;

    function unlockERC1155(
        address token,
        uint256 identifier,
        uint256 amount
    ) external;
}

contract ERC721VaultUnlocker {
    function safeTransferFrom(
        address, // from
        address to,
        uint256 id,
        uint256 value,
        bytes calldata // data
    ) external {
        IVault(to).unlockERC721(address(uint160(id)), value);
    }
}

contract ERC1155VaultUnlocker {
    function safeTransferFrom(
        address, // from
        address to,
        uint256 id,
        uint256 value,
        bytes calldata // data
    ) external {
        // The amount can be at most 12 bytes
        uint256 amount = id >> 160;
        IVault(to).unlockERC1155(address(uint160(id)), value, amount);
    }
}
