// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Ownable} from "openzeppelin/access/Ownable.sol";

// Via the "opt-out" list, creators are able to disallow collections they
// own from being tradeable on Forward. The owner of the contract has the
// power of overriding the status of any collection (useful in cases when
// the collection doesn't follow the standard ownership interface).
contract OptOutList is Ownable {
    // Errors

    error AlreadySet();
    error Unauthorized();

    // Events

    event OptOutListUpdated(address token, bool optedOut);

    // Fields

    mapping(address => bool) public optedOut;

    // Public methods

    function setOptOutStatus(address token, bool status) external {
        if (msg.sender != Ownable(token).owner()) {
            revert Unauthorized();
        }

        _setOptOutStatus(token, status);
    }

    // Restricted methods

    function adminSetOptOutStatus(address token, bool status) external {
        if (msg.sender != owner()) {
            revert Unauthorized();
        }

        _setOptOutStatus(token, status);
    }

    // Internal methods

    function _setOptOutStatus(address token, bool status) internal {
        if (optedOut[token] == status) {
            revert AlreadySet();
        }

        optedOut[token] = status;
        emit OptOutListUpdated(token, status);
    }
}
