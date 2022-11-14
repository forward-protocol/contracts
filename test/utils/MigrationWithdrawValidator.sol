// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {Forward} from "../../src/Forward.sol";

import {IWithdrawValidator} from "../../src/interfaces/IWithdrawValidator.sol";

// Withdraw validator contract for royalty-less migration to a new protocol instance
contract MigrationWithdrawValidator is IWithdrawValidator {
    // Private fields

    Forward private newInstance;

    // Constructor

    constructor(address _newInstance) {
        newInstance = Forward(_newInstance);
    }

    // Public methods

    function canSkipRoyalties(address from, address to)
        external
        view
        returns (bool)
    {
        // Only allow withdrawing to the user's vault on the new protocol instance
        address vault = address(newInstance.vaults(from));
        if (to == vault) {
            return true;
        }
        return false;
    }
}
