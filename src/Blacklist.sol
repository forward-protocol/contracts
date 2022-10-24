// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Ownable} from "openzeppelin/access/Ownable.sol";

// Via the blacklist, creators are able to disallow collections they own
// from being tradeable on Forward. The blacklist admin has the power of
// overriding the status of any collection (useful for collections which
// don't follow the standard ownership interface).
contract Blacklist is Ownable {
    // Errors

    error AlreadySet();
    error Unauthorized();

    // Events

    event BlacklistUpdated(address token, bool isBlacklisted);

    // Fields

    mapping(address => bool) public isBlacklisted;

    // Public methods

    function setBlacklistStatus(address token, bool status) external {
        if (msg.sender != Ownable(token).owner()) {
            revert Unauthorized();
        }

        _setBlacklistStatus(token, status);
    }

    // Restricted methods

    function adminSetBlacklistStatus(address token, bool status) external {
        if (msg.sender != owner()) {
            revert Unauthorized();
        }

        _setBlacklistStatus(token, status);
    }

    // Internal methods

    function _setBlacklistStatus(address token, bool status) internal {
        if (isBlacklisted[token] == status) {
            revert AlreadySet();
        }

        isBlacklisted[token] = status;
        emit BlacklistUpdated(token, status);
    }
}
