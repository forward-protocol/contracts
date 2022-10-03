// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IVault {
    function unlockERC721(address token, uint256 identifier) external;
}

// TODO: Integrate ERC155 unlocking

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
