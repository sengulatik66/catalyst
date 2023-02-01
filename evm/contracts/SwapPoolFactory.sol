// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.16;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./CatalystIBCInterface.sol";
import "./interfaces/ICatalystV1FactoryEvents.sol";

/**
 * @title Catalyst Swap Factory
 * @author Catalyst Labs
 * @notice Allows permissionless deployment Catalyst Swap pools
 * and defines governance address for swap pools to read..
 */
contract CatalystSwapPoolFactory is Ownable, ICatalystV1FactoryEvents {
    using SafeERC20 for IERC20;

    // By default, it is expected that:
    // 0: Volatile v1
    // 1: Amplified v1
    mapping(uint256 => address) public _poolTemplate;
    mapping(address => mapping(address => bool)) public IsCreatedByFactory;
    uint256 public _defaultPoolFee;
    uint256 public _defaultGovernanceFee;

    constructor(
        address volatilePoolTemplate,
        address amplifiedPoolTemplate,
        uint256 defaultPoolFee,
        uint256 defaultGovernanceFee
    ) {
        _poolTemplate[0] = volatilePoolTemplate;
        emit AddPoolTemplate(0, volatilePoolTemplate);

        _poolTemplate[1] = amplifiedPoolTemplate;
        emit AddPoolTemplate(1, amplifiedPoolTemplate);

        setDefaultPoolFee(defaultPoolFee);
        setDefaultGovernanceFee(defaultGovernanceFee);
    }

    function setDefaultPoolFee(uint256 fee) public onlyOwner {
        require(fee <= 100*10**16);  // dev: PoolFee is maximum 100%.

        emit SetDefaultPoolFee(fee);

        _defaultPoolFee = fee;        
    }

    function setDefaultGovernanceFee(uint256 fee) public onlyOwner {
        require(fee <= 75*10**16); // dev: GovernanceFee is maximum 75%.

        emit SetDefaultGovernanceFee(fee);

        _defaultGovernanceFee = fee;
    }

    function addPoolTemplate(address addressOfPoolTemplate, uint256 index)
        external
        onlyOwner
    {
        require(_poolTemplate[index] == address(0));
        _poolTemplate[index] = addressOfPoolTemplate;
        emit AddPoolTemplate(index, addressOfPoolTemplate);
    }

    /**
     * @notice Deploys a Catalyst swap pools, funds the swap pool with tokens and calls setup.
     * @dev The deployer needs to set approvals for this contract before calling deploy_swappool
     * @param poolTemplateIndex The template the transparent proxy should target.
     * @param init_assets The list of assets the pool should support
     * @param init_balances The initial balances of the swap pool. (Should be approved)
     * @param weights The weights of the tokens.
     * @param amp Token parameter 1. (Amplifications)
     * @param name Name of the Pool token.
     * @param symbol Symbol for the Pool token.
     * @param chaininterface The cross chain interface used for cross-chain swaps. (Can be address(0))
     * @return address The address of the created Catalyst Swap Pool (minimal transparent proxy)
     */
    function deploy_swappool(
        uint256 poolTemplateIndex,
        address[] calldata init_assets,
        uint256[] memory init_balances,
        uint256[] calldata weights,
        uint256 amp,
        string memory name,
        string memory symbol,
        address chaininterface
    ) external returns (address) {
        // Create a minimal transparent proxy:
        address swapPool = Clones.clone(_poolTemplate[poolTemplateIndex]);

        // TODO move this into the initializeSwapCurves function of the SwapPool?
        // The pool expects the balances to exist in the pool when setup is called.
        for (uint256 it = 0; it < init_assets.length; it++) {
            IERC20(init_assets[it]).safeTransferFrom(
                msg.sender,
                swapPool,
                init_balances[it]
            );
        }

        // Call setup
        ICatalystV1Pool(swapPool).setup(
            name,
            symbol,
            chaininterface,
            _defaultPoolFee,
            _defaultGovernanceFee,
            msg.sender,     // Fee administrator    //TODO should we set governance instead?
            msg.sender      // setup master
        );

        // Initialize swap curves
        ICatalystV1Pool(swapPool).initializeSwapCurves(
            init_assets,
            weights,
            amp,
            msg.sender
        );

        // Emit event for pool discovery.
        emit PoolDeployed(
            msg.sender,
            swapPool,
            chaininterface,
            amp,
            init_assets
        );
        IsCreatedByFactory[chaininterface][swapPool] = true;

        return swapPool;
    }
}
