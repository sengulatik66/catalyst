//SPDX-License-Identifier: Unlicsened
pragma solidity ^0.8.16;

/// @title Events emitted by Catalyst v1 Factory
/// @notice Contains all events emitted by the Factory
interface ICatalystV1FactoryEvents {
    /**
     * @notice  Describes an atomic swap between the 2 tokens: _fromAsset and _toAsset.
     * @dev Should be used for pool discovery and pathing.
     * @param deployer msg.sender of the deploy function.
     * @param pool_address The minimal transparent proxy address for the swap pool.
     * @param chaininterface The address of the CCI used by the transparent proxy.
     * @param k Set to 10**18 if the pool is volatile, otherwise the pool is a stable pool.
     * @param assets List of the assets the pool supports.
     */
    event PoolDeployed(
        address indexed deployer,
        address indexed pool_address,
        address indexed chaininterface, 
        uint256 k,
        address[] assets
    );

    /**
     * @notice Describes governance fee changes.
     * @dev Only applies to new pools, has no impact on existing pools.
     * @param oldDefaultGovernanceFee The governance fee which is to be overwritten.
     * @param newDefaultGovernanceFee The new governance fee.
     */
    event NewDefaultGovernanceFee(
        uint256 oldDefaultGovernanceFee,
        uint256 newDefaultGovernanceFee
    );

    /**
     * @notice Pool Template has been added.
     * @param poolTemplateIndex The index of the pool template.
     * @param templateAddress The address of the pool template.
     */
    event AddPoolTemplate(
        uint256 poolTemplateIndex,
        address templateAddress
    );
}