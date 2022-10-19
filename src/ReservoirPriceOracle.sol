// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

// Withdraw oracle messages can be short (eg. a few minutes)
// Seaport listings oracle messages have to include the order hash

contract ReservoirPriceOracle is IPriceOracle {
    // Public constants

    uint256 public TWAP_SECONDS = 60 * 60

    // Public methods

    function getCollectionFloorPriceByToken(
        bytes calldata onChainData,
        bytes calldata offChainData
    ) external view returns (uint256) {
        (address token, uint256 tokenId, address currency, uint256 maxMessageAge) = abi.decode(onChainData, (address, uint256, address, uint256));

        bytes32 id = keccak256(
            abi.encode(
                keccak256(
                    "CollectionPriceByToken(uint8 kind,uint256 twapSeconds,address token,address tokenId)"
                ),
                PriceKind.SPOT,
                0,
                token,
                tokenId
            )
        );

        // Validate the message
        if (!_verifyMessage(id, maxMessageAge, message)) {
            revert InvalidMessage();
        }

        (address messageCurrency, uint256 price) = abi.decode(
            message.payload,
            (address, uint256)
        );
        require(currency == messageCurrency, "Wrong currency");
    }

    // Internal methods

    function _verifyMessage(
        bytes32 id,
        uint256 validFor,
        Message memory message
    ) internal virtual returns (bool success) {
        // Ensure the message matches the requested id
        if (id != message.id) {
            return false;
        }

        // Ensure the message timestamp is valid
        if (
            message.timestamp > block.timestamp ||
            message.timestamp + validFor < block.timestamp
        ) {
            return false;
        }

        bytes32 r;
        bytes32 s;
        uint8 v;

        // Extract the individual signature fields from the signature
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }

        address signerAddress = ecrecover(
            keccak256(
                abi.encodePacked(
                    "\x19Ethereum Signed Message:\n32",
                    // EIP-712 structured-data hash
                    keccak256(
                        abi.encode(
                            keccak256(
                                "Message(bytes32 id,bytes payload,uint256 timestamp)"
                            ),
                            message.id,
                            keccak256(message.payload),
                            message.timestamp
                        )
                    )
                )
            ),
            v,
            r,
            s
        );

        // Ensure the signer matches the designated oracle address
        return signerAddress == RESERVOIR_ORACLE_ADDRESS;
    }
}
