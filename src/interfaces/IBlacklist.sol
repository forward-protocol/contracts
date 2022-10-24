// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IBlacklist {
    function isBlacklisted(address token) external view returns (bool status);
}
