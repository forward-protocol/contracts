// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ReservoirOracle} from "oracle/ReservoirOracle.sol";

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

contract ReservoirPriceOracle is IPriceOracle, ReservoirOracle {
    // Constructor

    constructor(address reservoirOracle) ReservoirOracle(reservoirOracle) {}

    // Public methods

    function getCollectionFloorPriceByToken(
        // On-chain data
        address token,
        uint256 tokenId,
        uint256 maxMessageAge,
        // Off-chain data
        bytes calldata offChainData
    ) external view override returns (uint256) {
        // Decode off-chain data
        ReservoirOracle.Message memory message = abi.decode(
            offChainData,
            (ReservoirOracle.Message)
        );

        // Construct the wanted message id
        bytes32 id = keccak256(
            abi.encode(
                keccak256(
                    "CollectionPriceByToken(uint8 kind,uint256 twapSeconds,address token,uint256 tokenId)"
                ),
                uint8(0), // PriceKind.SPOT
                uint256(0),
                token,
                tokenId
            )
        );

        // Validate the message
        if (!_verifyMessage(id, maxMessageAge, message)) {
            revert InvalidMessage();
        }

        // Decode the message's payload
        (address currency, uint256 price) = abi.decode(
            message.payload,
            (address, uint256)
        );

        // The currency should be ETH
        if (currency != address(0)) {
            revert InvalidMessage();
        }

        return price;
    }
}
