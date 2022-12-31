//SPDX-License-Identifier: Unlicsened

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./FixedPointMath.sol";
import "./CatalystIBCInterface.sol";
import "./SwapPoolCommon.sol";
import "./ICatalystV1Pool.sol";

/**
 * @title Catalyst: The Multi-Chain Swap pool
 * @author Catalyst Labs
 * @notice Catalyst multi-chain swap pool using the asset specific
 * pricing curve: W/(w · ln(2)) where W is an asset specific weight
 *  and w is the pool balance.
 *
 * The following contract supports between 1 and 3 assets for
 * atomic swaps. To increase the number of tokens supported,
 * change NUMASSETS to the desired maximum token amount.
 *
 * Implements the ERC20 specification, such that the contract
 * will be its own pool token.
 * @dev This contract is deployed /broken/: It cannot be used as a
 * swap pool as is. To use it, a proxy contract duplicating the
 * logic of this contract needs to be deployed. In vyper, this
 * can be done through (vy 0.3.4) create_minimal_proxy_to.
 * After deployment of the proxy, call setup(...). This will
 * initialize the pool and prepare it for cross-chain transactions.
 *
 * If connected to a supported cross-chain interface, call
 * createConnection or createConnectionWithChain to connect the
 * pool with pools on other chains.
 *
 * Finally, call finishSetup to give up the deployer's control
 * over the pool.
 */
contract CatalystSwapPoolAmplified is
    CatalystFixedPointMath,
    CatalystSwapPoolCommon
{
    using SafeERC20 for IERC20;

    //--- ERRORS ---//

    //--- Config ---//
    // The following section contains the configurable variables.

    //-- Variables --//
    uint256 public _amp;
    uint256 public _targetAmplification;

    // In the equation for the security limit, this constant appears.
    // The constant depends only amp but not on the pool balance.
    // As a result, it is computed on pool deployment.
    uint256 _ampUnitCONSTANT;

    // To keep track of group ownership, the pool needs to know the balance of units
    // for the pool.
    int128 public _unitTracker;

    // Is limited (*cannot overflow*) because the integral from 0 to C < \infty is finite. That means the number can never  < int_0^DepositedBalance
    // And since the sum of all unitTracker in the system is 0. The top side is also limited.

    /**
     * @notice Setup a pool.
     * @dev The @param amp is only used as a sanity check and needs to be set to 2**64.
     * If less than NUMASSETS are used to setup the pool, let the remaining init_assets be ZERO_ADDRESS
     * The unused weights can be whatever. (however, 0 is recommended.)
     * The initial token amounts should have been sent to the pool before setup.
     * If any token has token amount 0, the pool will never be able to have more than
     * 0 tokens for that token.
     */
    function setup(
        address[] calldata init_assets,
        uint256[] calldata weights,
        uint256 amp,
        uint256 governanceFee,
        string calldata name_,
        string calldata symbol_,
        address chaininterface,
        address setupMaster
    ) public {
        require(amp != ONE);
        require(init_assets.length <= NUMASSETS);
        _amp = amp;
        _targetAmplification = amp;
        _governanceFee = governanceFee;
        {
            uint256 max_unit_inflow = 0;
            for (uint256 it = 0; it < init_assets.length; it++) {
                address tokenAddress = init_assets[it];
                _tokenIndexing[it] = tokenAddress;
                _weight[tokenAddress] = weights[it];
                // The contract expect the tokens to have been sent to it before setup is
                // called. Make sure the pool has more than 0 tokens.

                uint256 balanceOfSelf = IERC20(tokenAddress).balanceOf(
                    address(this)
                );
                require(balanceOfSelf > 0); // dev: 0 tokens provided in setup.

                // The maximum unit flow is \sum Weights. The value is shifted 64
                // since units are always X64.
                max_unit_inflow +=
                    weights[it] *
                    fpowX64(balanceOfSelf << 64, ONE - amp);
            }
            _ampUnitCONSTANT = ONE - invp2X64(ONE - amp);
            _max_unit_inflow = mulX64(_ampUnitCONSTANT, max_unit_inflow);
        }

        setupBase(name_, symbol_, chaininterface, setupMaster);
    }

    function modifyWeights(uint256 targetTime, uint256[] calldata newWeights)
        external
        onlyFactoryOwner
    {
        require(targetTime >= block.timestamp + 60 * 60 * 24 * 2); // dev: targetTime must be more than 2 days in the future.
        require(_targetAmplification == _amp); // dev: Weight and amplification changes are disallowed simultaneously.
        _adjustmentTarget = targetTime + (targetTime % 2); // Weight changes have even target time
        _lastModificationTime = block.timestamp;

        uint256 amp = _amp;
        uint256 new_max_unit_inflow = 0;
        // We don't want to spend gas on each update, updating the security limit. As a result, we decrease security
        // for lower gas cost.
        for (uint256 it = 0; it < NUMASSETS; it++) {
            address token = _tokenIndexing[it];
            if (token == address(0)) break;
            _targetWeight[token] = newWeights[it]; // Set new weights

            uint256 balanceOfSelf = IERC20(token).balanceOf(address(this));
            new_max_unit_inflow +=
                newWeights[it] *
                fpowX64(balanceOfSelf << 64, ONE - amp); // Compute new security limit.
        }
        new_max_unit_inflow = mulX64(_ampUnitCONSTANT, new_max_unit_inflow);
        if (new_max_unit_inflow >= _max_unit_inflow) {
            // The governance can technically remove the security limit by setting targetTime = max(uint256)
            // while newWeights = (max(uint256)/NUMWEIGHTS) >> 64. Since the router and the governance are
            // to be independent, this is not a security issue.
            // Alt: Call with higher weights and then immediately call with lower weights.
            _max_unit_inflow = new_max_unit_inflow;
            _target_max_unit_inflow = 0;
        } else {
            // Decreases of the security limit can also be a way to remove the security limit. However, if the
            // weights are kept low (=1) (for cheaper tx costs), then this is non-issue since it cannot be
            // decerased further.
            // _max_unit_inflow = current_unit_inflow
            _target_max_unit_inflow = new_max_unit_inflow;
        }
    }

    /**
     * @notice If the governance requests a weight change, this function will adjust the pool weights.
     */
    function _W() internal {
        uint256 adjTarget = _adjustmentTarget;

        if ((adjTarget != 0) && (adjTarget % 2 == 0)) {
            uint256 currTime = block.timestamp;
            uint256 lastModification = _lastModificationTime;
            if (currTime == lastModification) return; // If no time has passed since last update, then we don't need to update anything.

            // If the current time is past the adjustment, then we need to finalise the weights.
            if (currTime >= adjTarget) {
                for (uint256 it = 0; it < NUMASSETS; it++) {
                    address token = _tokenIndexing[it];
                    if (token == address(0)) break;
                    uint256 targetWeight = _targetWeight[token];
                    // Only save weights if they are differnet.
                    if (_weight[token] != targetWeight) {
                        _weight[token] = targetWeight;
                    }
                }
                // Set weightAdjustmentTime to 0. This ensures the if statement is never entered.
                _adjustmentTarget = 0;
                _lastModificationTime = currTime;

                // Check if security limit needs to be updated.
                uint256 target_max_unit_inflow = _target_max_unit_inflow;
                if (target_max_unit_inflow != 0) {
                    _max_unit_inflow = target_max_unit_inflow;
                    _target_max_unit_inflow = 0;
                }
                return;
            }
            for (uint256 it = 0; it < NUMASSETS; it++) {
                address token = _tokenIndexing[it];
                if (token == address(0)) break;
                uint256 targetWeight = _targetWeight[token];
                uint256 currentWeight = _weight[token];
                if (currentWeight == targetWeight) {
                    continue;
                }
                uint256 newWeight;
                if (targetWeight > currentWeight) {
                    newWeight =
                        currentWeight +
                        ((targetWeight - currentWeight) *
                            (currTime - lastModification)) /
                        (adjTarget - lastModification);
                } else {
                    newWeight =
                        currentWeight -
                        ((currentWeight - targetWeight) *
                            (currTime - lastModification)) /
                        (adjTarget - lastModification);
                }
                _weight[token] = newWeight;
            }
            _lastModificationTime = currTime;
        }
    }

    function modifyAmplification(
        uint256 targetTime,
        uint256 targetAmplification
    ) external onlyFactoryOwner {
        require(targetTime >= block.timestamp + 60 * 60 * 24 * 2); // dev: targetTime must be more than 2 days in the future.
        if (_adjustmentTarget != 0) {
            require(_targetAmplification != _amp); // dev: Weight and amplification changes are disallowed simultaneously.
        }
        _adjustmentTarget = targetTime + (targetTime % 2) + 1; //  Weight changes have uneven target time
        _lastModificationTime = block.timestamp;
        _targetAmplification = targetAmplification;

        uint256 amp = targetAmplification;
        uint256 new_max_unit_inflow = 0;
        for (uint256 it = 0; it < NUMASSETS; it++) {
            address token = _tokenIndexing[it];
            if (token == address(0)) break;
            uint256 balanceOfSelf = IERC20(token).balanceOf(address(this));
            new_max_unit_inflow +=
                _weight[token] *
                fpowX64(balanceOfSelf << 64, ONE - amp);
        }
        uint256 newAmpUnitCONSTANT = ONE - invp2X64(ONE - amp);
        new_max_unit_inflow = mulX64(newAmpUnitCONSTANT, new_max_unit_inflow);
        // The governance abuse of the way the security limit is updated is low-impact for amplification.
        // Weight changes are way more efficient at removing the security limit.
        if (new_max_unit_inflow >= _max_unit_inflow) {
            _max_unit_inflow = new_max_unit_inflow;
            _target_max_unit_inflow = 0;
        } else {
            // _max_unit_inflow = current_unit_inflow
            _target_max_unit_inflow = new_max_unit_inflow;
        }
    }

    /**
     * @notice If the governance requests an amplifiaction change, this function will adjust the pool amplification.
     */
    function _A() internal {
        uint256 adjTarget = _adjustmentTarget;

        if ((adjTarget != 0) && (adjTarget % 2 == 1)) {
            uint256 currTime = block.timestamp;
            uint256 lastModification = _lastModificationTime;
            if (currTime == lastModification) return; // If no time has passed since last update, then we don't need to update anything.

            // If the current time is past the adjustment, then we need to finalise.
            if (currTime >= adjTarget) {
                _amp = _targetAmplification;

                // Set weightAdjustmentTime to 0. This ensures the if statement is never entered.
                _adjustmentTarget = 0;
                _lastModificationTime = currTime;

                // Check if security limit needs to be updated.
                uint256 target_max_unit_inflow = _target_max_unit_inflow;
                if (target_max_unit_inflow != 0) {
                    _max_unit_inflow = target_max_unit_inflow;
                    _target_max_unit_inflow = 0;
                }
                return;
            }
            uint256 currentAmplification = _amp;
            uint256 targetAmplification = _targetAmplification;
            uint256 newAmp;
            if (targetAmplification > currentAmplification) {
                newAmp =
                    currentAmplification +
                    ((targetAmplification - currentAmplification) *
                        (currTime - lastModification)) /
                    (adjTarget - lastModification);
            } else {
                newAmp =
                    currentAmplification -
                    ((currentAmplification - targetAmplification) *
                        (currTime - lastModification)) /
                    (adjTarget - lastModification);
            }
            _amp = newAmp;

            _ampUnitCONSTANT = ONE - invp2X64(ONE - newAmp);

            _lastModificationTime = currTime;
        }
    }

    /**
     * @notice The maximum unit flow changes depending on the current
     * balance for amplified pools. The change is
     *     (1-2^(k-1)) · W · b^(1-k) - (1-2^(k-1)) · W · a^(1-k)
     * where b is the balance after the swap and a is the balance
     * before the swap.
     * @dev Always returns uint256. If oldBalance > newBalance,
     * the return should be negative. (but the absolute)
     * value is returned instead.
     * @param oldBalance The old balance.
     * @param newBalance The new balance.
     * @param asset The asset which is being updated.
     * @return uint256 Returns the absolute change in unit capacity Returns without the ampConstant.
     */
    function getModifyUnitCapacity(
        uint256 oldBalance,
        uint256 newBalance,
        address asset
    ) internal view returns (uint256) {
        // If the balances doesn't change, the change is 0.
        if (oldBalance == newBalance) return 0;

        // Cache the relevant amplification
        uint256 oneMinusAmp = ONE - _amp;
        // Notice, a > b => a^(1-k) > b^(1-k) =>
        // a <= b => a^(1-k) <= b^(1-k)
        if (oldBalance < newBalance)
            // Since a^(1-k) > b^(1-k), the return is positive
            return
                _weight[asset] *
                (fpowX64(newBalance << 64, oneMinusAmp) -
                    fpowX64(oldBalance << 64, oneMinusAmp));

        // Since a^(1-k) > b^(1-k), the return is negative
        // Since the function returns uint256, return
        // b^(1-k) - a^(1-k) instead. (since that is positive)
        return
            _weight[asset] *
            (fpowX64(oldBalance << 64, oneMinusAmp) -
                fpowX64(newBalance << 64, oneMinusAmp));
    }

    //--- Swap integrals ---//
    // Unlike the ordinary swaps, amplified swaps do not get simpler
    // by approximating the curve.
    // When deriving the SwapFromUnits equation, _out is not directly
    // given. Instead it has to be solved. And depending on the complexity
    // of the price curve, the solution to _out = ... is not simple.

    /**
     * @notice Computes the integral
     * \int_{A}^{A+in} W/w^k · (1-k) dw
     *     = W · ( (A + _in)^(1-k) - A^(1-k) )
     * The value is returned as units, which is always in X64.
     * @dev All input amounts should be the raw numbers and not X64.
     * Since units are always denominated in X64, the function
     * should be treated as mathematically *native*.
     * @param input The input amount.
     * @param A The current pool balance.
     * @param W The pool weight of the token.
     * @param amp The amplification.
     * @return uint256 Group specific units in X64 (units are **always** X64).
     */
    function compute_integral(
        uint256 input,
        uint256 A,
        uint256 W,
        uint256 amp
    ) internal pure returns (uint256) {
        uint256 oneMinusAmp = ONE - amp; // Minor gas saving :)
        return
            W *
            (fpowX64((A + input) << 64, oneMinusAmp) -
                fpowX64(A << 64, oneMinusAmp));
    }

    /**
     * @notice Solves the equation U = \int_{A-_out}^{A} W/w^k · (1-k) dw for _out
     *     = B ·
     *     (
     *         1 - (
     *             (W_B · B^(1-k) - U) / (W_B · B^(1-k))
     *         )^(1/(1-k))
     *     )
     *
     * The value is returned as output token.
     * @dev All input amounts should be the raw numbers and not X64.
     * Since units are always denominated in X64, the function
     * should be treated as mathematically *native*.
     * @param U Input units. Is technically X64 but can be treated as not.
     * @param B The current pool balance of the _out token.
     * @param W The pool weight of the _out token.
     * @return uint256 Output denominated in output token.
     */
    function solve_integral(
        uint256 U,
        uint256 B,
        uint256 W,
        uint256 amp
    ) internal pure returns (uint256) {
        uint256 oneMinusAmp = ONE - amp; // Minor gas saving :)
        // W_B · B^(1-k) is repeated twice and requires 1 power.
        // As a result, we compute it and cache.
        uint256 W_BTimesBtoOneMinusAmp = W * fpowX64(B << 64, oneMinusAmp);
        return
            (B *
                (ONE -
                    invfpowX64(
                        bigdiv64(
                            W_BTimesBtoOneMinusAmp,
                            W_BTimesBtoOneMinusAmp - U
                        ),
                        bigdiv64(ONE, oneMinusAmp)
                    ))) >> 64;
    }

    /**
     * @notice Solves the equation
     *     \int_{A}^{A + _in} W_A/w^k · (1-k) dw = \int_{B-_out}^{B} W_B/w^k · (1-k) dw for _out
     *         => out = B ·
     *         (
     *             1 - (
     *                 (W_B · B^(1-k) - W_A · ((A+x)^(1-k) - A^(1-k)) / (W_B · B^(1-k))
     *             )^(1/(1-k))
     *         )
     *
     * Alternatively, the integral can be computed through:
     *     _solve_integral(_compute_integral(input, A, W_A, amp), _B, _W_B, amp).
     *     However, _complete_integral is very slightly cheaper since it doesn't
     *     compute oneMinusAmp twice. :)
     *     (Apart from that, the mathematical operations are the same.)
     * @dev All input amounts should be the raw numbers and not X64.
     * @param input The input amount.
     * @param A The current pool balance of the _in token.
     * @param B The current pool balance of the _out token.
     * @param W_A The pool weight of the _in token.
     * @param W_B The pool weight of the _out token.
     * @param amp The amplification.
     * @return uint256 Output denominated in output token.
     */
    function complete_integral(
        uint256 input,
        uint256 A,
        uint256 B,
        uint256 W_A,
        uint256 W_B,
        uint256 amp
    ) internal pure returns (uint256) {
        uint256 oneMinusAmp = ONE - amp; // Minor gas saving :)
        uint256 W_BTimesBtoOneMinusAmp = W_B * fpowX64(B << 64, oneMinusAmp);
        return
            (B *
                (ONE -
                    invfpowX64(
                        bigdiv64(
                            W_BTimesBtoOneMinusAmp,
                            W_BTimesBtoOneMinusAmp -
                                W_A *
                                (fpowX64((A + input) << 64, oneMinusAmp) -
                                    fpowX64(A << 64, oneMinusAmp))
                        ),
                        bigdiv64(ONE, oneMinusAmp)
                    ))) >> 64;
    }

    /**
     * @notice Computes the return of a SwapToUnits, without executing one.
     * @dev Unlike a non-amplified pool, there is not simple swap curve approximation for amplified pools.
     * @param from The address of the token to sell.
     * @param amount The amount of _from token to sell.
     * @return uint256 Group specific units in X64 (units are **always** X64).
     */
    function dry_swap_to_unit(address from, uint256 amount)
        public
        view
        returns (uint256)
    {
        uint256 W = _weight[from];
        uint256 A = IERC20(from).balanceOf(address(this));
        require(A + amount < 2**(256 - 64) - 1, BALANCE_SECURITY_LIMIT); // dev: Potential exploitable
        // if the attacker can abuse
        // some kind of flash-mint.

        return compute_integral(amount, A, W, _amp);
    }

    /**
     * @notice Computes the output of a SwapFromUnits, without executing one.
     * @dev Unlike a non-amplified pool, there is not simple swap curve approximation for amplified pools.
     * @param to The address of the token to buy.
     * @param U The number of units used to buy to.
     * @return uint256 Output denominated in output token.
     */
    function dry_swap_from_unit(address to, uint256 U)
        public
        view
        returns (uint256)
    {
        uint256 W = _weight[to];
        uint256 B = IERC20(to).balanceOf(address(this)) - _escrowedTokens[to];
        require(B < 2**(256 - 64) - 1, BALANCE_SECURITY_LIMIT); // dev: Potential exploitable
        // if the attacker can abuse
        // some kind of flash-mint.

        return solve_integral(U, B, W, _amp);
    }

    /**
     * @notice Computes the return of a SwapToAndFromUnits, without executing one.
     * @param from The address of the token to sell.
     * @param to The address of the token to buy.
     * @param input The amount of _from token to sell for to token.
     * @return uint256 Output denominated in to token. */
    function dry_swap_both(
        address from,
        address to,
        uint256 input
    ) public view returns (uint256) {
        uint256 A = IERC20(from).balanceOf(address(this));
        uint256 B = IERC20(to).balanceOf(address(this)) - _escrowedTokens[to];
        uint256 W_A = _weight[from];
        uint256 W_B = _weight[to];
        require(B < 2**(256 - 64) - 1, BALANCE_SECURITY_LIMIT); // dev: Potential exploitable
        // if the attacker can abuse
        // some kind of flash-mint.

        require(A + input < 2**(256 - 64) - 1, BALANCE_SECURITY_LIMIT); // dev: Potential exploitable
        // if the attacker can abuse
        // some kind of flash-mint.

        return complete_integral(input, A, B, W_A, W_B, _amp);
    }


    /**
     * @notice Deposits a symmetrical number of tokens such that in 1:1 wpt_a are deposited. This doesn't change the pool price.
     * @dev Requires approvals for all tokens within the pool.
     * @param wpt_a The number of pool tokens to mint.
     * @param minOut The minimum number of tokens minted.
     */
    function depositAll(uint256 wpt_a, uint256 minOut) external {
        // Cache weights and balances.
        uint256 oneMinusAmp = ONE - _amp;
        address[NUMASSETS] memory tokenIndexed = new address[](NUMASSETS);
        uint256[NUMASSETS] memory weightAssetBalances = new uint256[](NUMASSETS);
        uint256[NUMASSETS] memory ampWeightAssetBalances = new uint256[](NUMASSETS);
        uint256[NUMASSETS] memory assetWeights = new uint256[](NUMASSETS);

        uint256 walpha_0_ampped;
        // First, lets derive walpha_0. This lets us evaluate the number of tokens the pool should have
        // If the price in the group is 1:1.
        { // We don't need weightedAssetBalanceSum again.
            uint256 weightedAssetBalanceSum = 0;
            for (uint256 it = 0; it < NUMASSETS; it++) {
                address token = _tokenIndexing[it];
                if (token == address(0)) break;
                tokenIndexed[it] = token;
                uint256 weight = _weight[token];
                assetWeights[it] = weight;

                // Not minus escrowedAmount, since we want the deposit to return less.
                uint256 weightAssetBalance = weight * ERC20(token).balanceOf(address(this));
                weightAssetBalances[it] = weightAssetBalance;  // Store since we need it later

                uint256 wab = fpowX64((weightAssetBalance) << 64, oneMinusAmp);  
                ampWeightAssetBalances[it] = wab;  // Store since it is an expensive calculation.
                weightedAssetBalanceSum += wab;
            }
            walpha_0_ampped = weightedAssetBalanceSum - _unitTracker;
        }


        // For later event logging, the amounts transferred to the pool are stored.
        uint256[] memory amounts = new uint256[](NUMASSETS);
        uint256 walpha_0 = fpowX64(walpha_0_ampped, ONEONE/(oneMinusAmp)); // todo: Optimise?
        uint256 poolTokens = (wpt_a * totalSupply())/walpha_0;
        require(poolTokens >= minOut, SWAP_RETURN_INSUFFICIENT);
        {
            uint256 innerdiff = fpowX64(walpha_0 + wpt_a, oneMinusAmp) - walpha_0_ampped;   
            for (uint256 it = 0; it < NUMASSETS; it++) {
                address token = tokenIndexed[it];
                if (token == address(0)) break;

                uint256 tokenAmount = fpowX64(ampWeightAssetBalances + innerdiff, ONEONE/(oneMinusAmp)) - weightAssetBalances[it] << 64;

                // Transfer the appropriate number of tokens from the user to the pool. (And store for event logging)
                amounts[it] = tokenAmount;
                IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount); // dev: User doesn't have enough tokens or low approval
            }
        }
        // Mint the desired number of pool tokens to the user.
        _mint(msg.sender, poolTokens);

        emit Deposit(msg.sender, poolTokens, amounts);
    }

    // @nonreentrant('lock')
    /**
     * @notice Deposits a symmetrical number of tokens such that in 1:1 wpt_a are deposited. This doesn't change the pool price.
     * @dev Requires approvals for all tokens within the pool.
     * @param poolTokens The number of pool tokens to mint.
     * @param minOut The minimum number of tokens minted.
     */
    function withdrawAll(uint256 poolTokens, uint256[] calldata minOut) public {
        // Burn the desired number of pool tokens to the user. If they don't have it, it saves gas.
        _burn(msg.sender, poolTokens);
        
        // Cache weights and balances.
        uint256 oneMinusAmp = ONE - _amp;
        address[NUMASSETS] memory tokenIndexed = new address[](NUMASSETS);
        uint256[NUMASSETS] memory weightAssetBalances = new uint256[](NUMASSETS);
        uint256[NUMASSETS] memory ampWeightAssetBalances = new uint256[](NUMASSETS);
        uint256[NUMASSETS] memory assetWeights = new uint256[](NUMASSETS);

        uint256 walpha_0_ampped;
        // First, lets derive walpha_0. This lets us evaluate the number of tokens the pool should have
        // If the price in the group is 1:1.
        { // We don't need weightedAssetBalanceSum again.
            uint256 weightedAssetBalanceSum = 0;
            for (uint256 it = 0; it < NUMASSETS; it++) {
                address token = _tokenIndexing[it];
                if (token == address(0)) break;
                tokenIndexed[it] = token;
                uint256 weight = _weight[token];
                assetWeights[it] = weight;

                // minus escrowedAmount, since we want the withdrawal to return less.
                uint256 weightAssetBalance = weight * (ERC20(token).balanceOf(address(this)) - _escrowedTokens[token]);
                weightAssetBalances[it] = weightAssetBalance;  // Store since we need it later

                uint256 wab = fpowX64((weightAssetBalance) << 64, oneMinusAmp);  
                ampWeightAssetBalances[it] = wab;  // Store since it is an expensive calculation.
                weightedAssetBalanceSum += wab;
            }
            walpha_0_ampped = weightedAssetBalanceSum - _unitTracker;
        }


        // For later event logging, the amounts transferred to the pool are stored.
        uint256[] memory amounts = new uint256[](NUMASSETS);
        uint256 walpha_0 = fpowX64(walpha_0_ampped, ONEONE/(oneMinusAmp));
        // solve: poolTokens = (wpt_a * (totalSupply() + poolTokens))/walpha_0; for wpt_a.
        // Plus _escrowedPoolTokens since we want the withdrawal to return less.
        uint256 wpt_a = (walpha_0 * poolTokens)/(totalSupply() + _escrowedPoolTokens + poolTokens);  // Remember to add the number of pool tokens burned to totalSupply
        {
            uint256 innerdiff = fpowX64(walpha_0 + wpt_a, oneMinusAmp) - walpha_0_ampped;   
            for (uint256 it = 0; it < NUMASSETS; it++) {
                address token = tokenIndexed[it];
                if (token == address(0)) break;

                uint256 tokenAmount = fpowX64(ampWeightAssetBalances + innerdiff, ONEONE/(oneMinusAmp)) - weightAssetBalances[it] << 64;
                
                if (tokenAmount > weightAssetBalances[it]/_weight[it]) {
                    //! If the pool doesn't have enough assets for a withdrawal, then
                    //! withdraw all of the pools assets. This should be protected against by setting minOut != 0.
                    //! This is possible because the pool expects assets to come back. (it is owed assets)
                    tokenAmount = weightAssetBalances[it]/_weight[it];
                    require(tokenAmount >= minOut[it], SWAP_RETURN_INSUFFICIENT);
                    // Transfer the appropriate number of tokens from the user to the pool. (And store for event logging)
                    amounts[it] = tokenAmount;
                    IERC20(token).transfer(msg.sender, tokenAmount); // dev: User doesn't have enough tokens or low approval
                    continue;
                }
                // Transfer the appropriate number of tokens from the user to the pool. (And store for event logging)
                amounts[it] = tokenAmount;
                IERC20(token).transfer(msg.sender, tokenAmount);
            }
        }

        emit Deposit(msg.sender, poolTokens, amounts);
    }


    // @nonreentrant('lock')
    /**
     * @notice A swap between 2 assets which both are inside the pool. Is atomic.
     * @param fromAsset The asset the user wants to sell.
     * @param toAsset The asset the user wants to buy
     * @param amount The amount of _fromAsset the user wants to sell
     * @param minOut The minimum output of _toAsset the user wants.
     */
    function localswap(
        address fromAsset,
        address toAsset,
        uint256 amount,
        uint256 minOut
    ) public returns (uint256) {
        _W();
        _A();
        uint256 fee = mulX64(amount, _poolFeeX64);

        // Calculate the swap return value.
        uint256 out = dry_swap_both(fromAsset, toAsset, amount - fee);

        // Check if the calculated returned value is more than the minimum output.
        require(out >= minOut, SWAP_RETURN_INSUFFICIENT);

        // Swap tokens with the user.
        IERC20(toAsset).safeTransfer(msg.sender, out);
        IERC20(fromAsset).safeTransferFrom(msg.sender, address(this), amount);

        // uint256 unitConstant = _ampUnitCONSTANT;
        // # Since the token limit depend on the current balance and all NUMASSETS
        // # assets have been updated, we should recalculate the limit.
        // # While we could compute each update separate, it would require 4 powers
        // # and recomputing it requires max NUMASSETS (3).
        // newUnitLimit: uint256 = 0
        // oneMinusAmp : uint256 = ONE - self.amp
        // for asset_num in range(NUMASSETS):
        //     asset : address = self.tokenIndexing[asset_num]
        //     if asset == ZERO_ADDRESS:
        //         break
        //     newUnitLimit += self.weight[asset] * self._fpowX64(shift(self.balance0[asset], 64), oneMinusAmp)

        // self.max_liquidity_unit_inflow = self.pMULX64(self.ampLiquidityUnitCONSTANT, newUnitLimit)

        emit LocalSwap(msg.sender, fromAsset, toAsset, amount, out, fee);

        return out;
    }

    function localswap(
        address fromAsset,
        address toAsset,
        uint256 amount,
        uint256 minOut,
        bool approx
    ) external returns (uint256) {
        return localswap(fromAsset, toAsset, amount, minOut);
    }

    function swapToUnits(
        uint32 chain,
        bytes32 targetPool,
        bytes32 targetUser,
        address fromAsset,
        uint8 toAssetIndex,
        uint256 amount,
        uint256 minOut,
        address fallbackUser,
        bytes memory calldata_
    ) internal returns (uint256) {
        require(fallbackUser != address(0));
        _W();
        _A();
        // uint256 fee = mulX64(amount, _poolFeeX64);

        // Calculate the group specific units bought.
        uint256 U = dry_swap_to_unit(
            fromAsset,
            amount - mulX64(amount, _poolFeeX64)
        );

        bytes32 messageHash;

        {TokenEscrow memory escrowInformation = TokenEscrow({
            amount: amount - mulX64(amount, _poolFeeX64),
            token: fromAsset
        });

        // Send the purchased units to targetPool on chain.
        messageHash = CatalystIBCInterface(_chaininterface).crossChainSwap(
            chain,
            targetPool,
            targetUser,
            toAssetIndex,
            U,
            minOut,
            false,
            escrowInformation,
            calldata_
        );}

        // Collect the tokens from the user.
        IERC20(fromAsset).safeTransferFrom(msg.sender, address(this), amount);

        // Escrow the tokens
        require(_escrowedFor[messageHash] == address(0)); // User cannot supply fallbackUser = address(0)
        _escrowedTokens[fromAsset] += amount - mulX64(amount, _poolFeeX64);
        _escrowedFor[messageHash] = fallbackUser;

        // Track units for fee distribution.
        _unitTracker += int128(U);

        // Compute the change in max_unit_inflow.
        {
            uint256 fromBalance = ERC20(fromAsset).balanceOf(address(this));
            _max_unit_inflow += mulX64(
                _ampUnitCONSTANT,
                getModifyUnitCapacity(
                    fromBalance - (amount - mulX64(amount, _poolFeeX64)),
                    fromBalance,
                    fromAsset
                )
            );
        }

        {
            // Governance Fee
            uint256 governanceFee = _governanceFee;
            if (governanceFee != 0) {
                uint256 governancePart = mulX64(
                    mulX64(amount, _poolFeeX64),
                    governanceFee
                );
                IERC20(fromAsset).safeTransfer(factoryOwner(), governancePart);
            }
        }

        // Adjustment of the security limit is delayed until ack to avoid
        // a router abusing timeout to circumvent the security limit at low cost.

        emit SwapToUnits(
            targetPool,
            targetUser,
            fromAsset,
            toAssetIndex,
            amount,
            U,
            minOut,
            messageHash
        );

        return U;
    }

    /**
     * @notice Initiate a cross-chain swap by purchasing units and transfer them to another pool.
     * @param chain The target chain. Will be converted by the interface to channelId.
     * @param targetPool The target pool on the target chain encoded in bytes32. For EVM chains this can be computed as:
     * Vyper: convert(_poolAddress, bytes32)
     * Solidity: abi.encode(_poolAddress)
     * Brownie: brownie.convert.to_bytes(_poolAddress, type_str="bytes32")
     * @param targetUser The recipient of the transaction on _chain. Encoded in bytes32. For EVM chains it can be derived similarly to targetPool.
     * @param fromAsset The asset the user wants to sell.
     * @param toAssetIndex The index of the asset the user wants to buy in the target pool.
     * @param amount The number of _fromAsset to sell to the pool.
     * @param minOut The minimum number of returned tokens to the targetUser on the target chain.
     * @param approx Unused
     * @param fallbackUser If the transaction fails send the escrowed funds to this address
     */
    function swapToUnits(
        uint32 chain,
        bytes32 targetPool,
        bytes32 targetUser,
        address fromAsset,
        uint8 toAssetIndex,
        uint256 amount,
        uint256 minOut,
        uint8 approx,
        address fallbackUser,
        bytes memory calldata_
    ) external returns (uint256) {
        return
            swapToUnits(
                chain,
                targetPool,
                targetUser,
                fromAsset,
                toAssetIndex,
                amount,
                minOut,
                fallbackUser,
                calldata_
            );
    }

    /**
     * @notice Initiate a cross-chain swap by purchasing units and transfer them to another pool.
     * @param chain The target chain. Will be converted by the interface to channelId.
     * @param targetPool The target pool on the target chain encoded in bytes32. For EVM chains this can be computed as:
     * Vyper: convert(_poolAddress, bytes32)
     * Solidity: abi.encode(_poolAddress)
     * Brownie: brownie.convert.to_bytes(_poolAddress, type_str="bytes32")
     * @param targetUser The recipient of the transaction on _chain. Encoded in bytes32. For EVM chains it can be derived similarly to targetPool.
     * @param fromAsset The asset the user wants to sell.
     * @param toAssetIndex The index of the asset the user wants to buy in the target pool.
     * @param amount The number of _fromAsset to sell to the pool.
     * @param minOut The minimum number of returned tokens to the targetUser on the target chain.
     * @param approx Unused
     * @param fallbackUser If the transaction fails send the escrowed funds to this address
     */
    function swapToUnits(
        uint32 chain,
        bytes32 targetPool,
        bytes32 targetUser,
        address fromAsset,
        uint8 toAssetIndex,
        uint256 amount,
        uint256 minOut,
        uint8 approx,
        address fallbackUser
    ) external returns (uint256) {
        bytes memory calldata_ = new bytes(0);
        return swapToUnits(
            chain,
            targetPool,
            targetUser,
            fromAsset,
            toAssetIndex,
            amount,
            minOut,
            fallbackUser,
            calldata_
        );
    }

    /**
     * @notice Completes a cross-chain swap by converting units to the desired token (toAsset)
     * Called exclusively by the chaininterface.
     * @dev Can only be called by the chaininterface, as there is no way to check the
     * validity of units.
     * @param toAssetIndex Index of the asset to be purchased with _U units.
     * @param who The recipient of toAsset
     * @param U Number of units to convert into toAsset.
     * @param minOut Minimum number of tokens bought. Reverts if less.
     * @param approx Ignored
     */
    function swapFromUnits(
        uint256 toAssetIndex,
        address who,
        uint256 U,
        uint256 minOut,
        bool approx,
        bytes32 messageHash
    ) public returns (uint256) {
        _W();
        _A();
        // The chaininterface is the only valid caller of this function, as there cannot
        // be a check of U. (It is purely a number)
        require(msg.sender == _chaininterface);
        // Convert the asset index (toAsset) into the asset to be purchased.
        address toAsset = _tokenIndexing[toAssetIndex];

        // Check if the swap is according to the swap limits
        checkAndSetUnitCapacity(U);

        // Calculate the swap return value.
        uint256 purchasedTokens = dry_swap_from_unit(toAsset, U);

        require(minOut <= purchasedTokens, SWAP_RETURN_INSUFFICIENT);

        // Send the return value to the user.
        IERC20(toAsset).safeTransfer(who, purchasedTokens);

        // Track units for fee distribution.
        _unitTracker -= int128(U);

        // Compute the change in max_unit_inflow.
        uint256 toBalance = IERC20(toAsset).balanceOf(address(this)) -
            _escrowedTokens[toAsset];
        _max_unit_inflow -= mulX64(
            _ampUnitCONSTANT,
            getModifyUnitCapacity(
                toBalance + purchasedTokens,
                toBalance,
                toAsset
            )
        );

        emit SwapFromUnits(who, toAsset, U, purchasedTokens, messageHash);

        return purchasedTokens; // Unused.
    }

    function swapFromUnits(
        uint256 toAssetIndex,
        address who,
        uint256 U,
        uint256 minOut,
        bool approx,
        bytes32 messageHash,
        address dataTarget,
        bytes calldata data
    ) external returns (uint256) {
        uint256 purchasedTokens = swapFromUnits(
            toAssetIndex,
            who,
            U,
            minOut,
            approx,
            messageHash
        );

        ICatalystReceiver(dataTarget).onCatalystCall(purchasedTokens, data);

        return purchasedTokens;
    }

    //--- Liquidity swapping ---//
    // Because of the way pool tokens work in a group of pools, there
    // needs to be a way to manage an equilibrium between pool token
    // value and token pool value. Liquidity swaps is a macro implemented
    // on the smart contract level to:
    // 1. Withdraw tokens.
    // 2. Convert tokens to units & transfer to target pool.
    // 3. Convert units to an even mix of tokens.
    // 4. Deposit the even mix of tokens.
    // In 1 user invocation.


    // @nonreentrant('lock')
    /**
     * @notice Initiate a cross-chain liquidity swap by lowering liquidity and transfer the liquidity units to another pool.
     * @param chain The target chain. Will be converted by the interface to channelId.
     * @param targetPool The target pool on the target chain encoded in bytes32. For EVM chains this can be computed as:
     * Vyper: convert(_poolAddress, bytes32)
     * Solidity: abi.encode(_poolAddress)
     * Brownie: brownie.convert.to_bytes(_poolAddress, type_str="bytes32")
     * @param targetUser The recipient of the transaction on _chain. Encoded in bytes32. For EVM chains it can be found similarly to _targetPool.
     * @param poolTokens The number of pool tokens to liquidity Swap
     * @param approx Unused
     */
    function outLiquidity(
        uint256 chain,
        bytes32 targetPool,
        bytes32 targetUser,
        uint256 poolTokens,
        uint256 minOut,
        uint8 approx,
        address fallbackUser
    ) external returns (uint256) {
        require(fallbackUser != address(0));
        _W();
        _A();
        // Cache totalSupply. This saves up to ~200 gas.
        uint256 initial_totalSupply = totalSupply() + _escrowedPoolTokens;

        // Since we have already cached totalSupply, we might as well burn the tokens
        // now. If the user doesn't have enough tokens, they save a bit of gas.
        _burn(msg.sender, poolTokens);
        
        // Cache weights and balances.
        uint256 oneMinusAmp = ONE - _amp;
        address[NUMASSETS] memory tokenIndexed = new address[](NUMASSETS);
        uint256[NUMASSETS] memory weightAssetBalances = new uint256[](NUMASSETS);
        uint256[NUMASSETS] memory ampWeightAssetBalances = new uint256[](NUMASSETS);
        uint256[NUMASSETS] memory assetWeights = new uint256[](NUMASSETS);

        uint256 walpha_0_ampped;
        // First, lets derive walpha_0. This lets us evaluate the number of tokens the pool should have
        // If the price in the group is 1:1.
        { // We don't need weightedAssetBalanceSum again.
            uint256 weightedAssetBalanceSum = 0;
            for (uint256 it = 0; it < NUMASSETS; it++) {
                address token = _tokenIndexing[it];
                if (token == address(0)) break;
                tokenIndexed[it] = token;
                uint256 weight = _weight[token];
                assetWeights[it] = weight;

                // minus escrowedAmount, since we want the withdrawal to return less.
                uint256 weightAssetBalance = weight * (ERC20(token).balanceOf(address(this)) - _escrowedTokens[token]);
                weightAssetBalances[it] = weightAssetBalance;  // Store since we need it later

                uint256 wab = fpowX64((weightAssetBalance) << 64, oneMinusAmp);  
                ampWeightAssetBalances[it] = wab;  // Store since it is an expensive calculation.
                weightedAssetBalanceSum += wab;
            }
            walpha_0_ampped = weightedAssetBalanceSum - _unitTracker;
        }


        uint256 U = 0;
        {
            uint256 walpha_0 = fpowX64(walpha_0_ampped, ONEONE/(oneMinusAmp));
            // solve: poolTokens = (wpt_a * (totalSupply() + poolTokens))/walpha_0; for wpt_a.
            // Plus _escrowedPoolTokens since we want the withdrawal to return less.
            uint256 wpt_a = (walpha_0 * poolTokens)/(totalSupply() + _escrowedPoolTokens + poolTokens);  // Remember to add the number of pool tokens burned to totalSupply
            {
                uint256 innerdiff = fpowX64(walpha_0 + wpt_a, oneMinusAmp) - walpha_0_ampped;   
                for (uint256 it = 0; it < NUMASSETS; it++) {
                    address token = tokenIndexed[it];
                    if (token == address(0)) break;

                    // 1. Withdraw tokens.
                    // Withdrawals should returns less, so the escrowed tokens are subtracted.
                    uint256 tokenAmount = fpowX64(ampWeightAssetBalances + innerdiff, ONEONE/(oneMinusAmp)) - weightAssetBalances[it] << 64;

                    // 2. Convert tokens to units
                    uint256 W = _weight[token];
                    uint256 A = weightAssetBalances/W;
                    require(A + tokenAmount < 2**(256 - 64) - 1, BALANCE_SECURITY_LIMIT); // dev: Potential exploitable
                                                                                        // if the attacker can abuse
                                                                                        // some kind of flash-mint.

                    U += compute_integral(tokenAmount, A, W, ONE - oneMinusAmp);
                }
            }
        }

        bytes32 messageHash;
        {
            LiquidityEscrow memory escrowInformation = LiquidityEscrow({
                poolTokens: poolTokens
            });

            // Sending the liquidity units over.
            messageHash = CatalystIBCInterface(_chaininterface).liquiditySwap(
                chain,
                targetPool,
                targetUser,
                U,
                minOut,
                false,
                escrowInformation
            );
        }

        // Escrow the pool tokens
        require(_escrowedLiquidityFor[messageHash] == address(0));
        _escrowedLiquidityFor[messageHash] = fallbackUser;
        _escrowedPoolTokens += poolTokens;

        // Adjustment of the security limit is delayed until ack to avoid
        // a router abusing timeout to circumvent the security limit at low cost.
        emit SwapToLiquidityUnits(
            targetPool,
            targetUser,
            poolTokens,
            U,
            0,
            messageHash
        );

        return U;
    }

    /**
     * @notice Solves the non-unique swap integral.
     * @dev All input amounts should be the raw numbers and not X64.
     * Since units are always denominated in X64, the function
     * should be treated as mathematically *native*.
     * The function is only to be used for liquidity swaps.
     * @param U Input units. Is technically X64 but can be treated as not.
     * @param W The pool weight of the _out token.
     * @return Output denominated in percentage of pool.
     */
    function arbitrary_solve_integralX64(
        uint256 U,
        uint256 W,
        uint256 amp
    ) internal pure returns (uint256) {
        uint256 oneMinusAmp = ONE - amp; // Minor gas saving :)
        // W_B · B^(1-k) is repeated twice and requires 1 power.
        // As a result, we compute it and cache.
        uint256 W_BTimesBtoOneMinusAmp = W * fpowX64(B << 64, oneMinusAmp);
        return (ONE - invfpowX64(bigdiv64(W_BTimesBtoOneMinusAmp, W_BTimesBtoOneMinusAmp - U), bigdiv64(ONE, oneMinusAmp)));
    }

    // @nonreentrant('lock')
    /**
     * @notice Completes a cross-chain swap by converting liquidity units to pool tokens
     * Called exclusively by the chaininterface.
     * @dev Can only be called by the chaininterface, as there is no way
     * to check the validity of units.
     * @param who The recipient of pool tokens
     * @param U Number of units to convert into pool tokens.
     * @param approx Ignored
     */
    function inLiquidity(
        address who,
        uint256 U,
        uint256 minOut,
        bool approx,
        bytes32 messageHash
    ) external returns (uint256) {
        _W();
        _A();
        // The chaininterface is the only valid caller of this function, as there cannot
        // be a check of _U. (It is purely a number)
        require(msg.sender == _chaininterface);

        // The units should be distributed in such a way that the balance0
        // ratio is the same before and after the swap. Since the weights depends
        // on the current pool token balance, it cannot be cached.
        uint256 WSUM = 0; // is X64.
        address[] memory tokens = new address[](NUMASSETS);
        uint256 oneMinusAmp = ONE - _amp;

        uint256 it = 0;
        for (; it < NUMASSETS; it++) {
            address token = _tokenIndexing[it];
            if (token == address(0)) break;

            tokens[it] = token;

            WSUM +=
                _weight[token] *
                fpowX64(_balance0[token] << 64, oneMinusAmp);
        }

        address token0 = _tokenIndexing[0];
        // Because of the balance0 constraint of wrapped pool tokens,
        // only the first balance0 change needs to be computed.
        uint256 token0B0 = dry_liquidity_from_unit(token0, U, WSUM);

        uint256 ts = totalSupply(); // Not! + _escrowedPoolTokens, since a smaller supply results in fewer pool tokens.
        // Token0B0 * _baseAmount = self.balance0
        // To increase the resolution, the balance0s are converted into pool tokens.
        // Since 2**64 is the reference liquidity and 2**64 is a lot larger than most token
        // amounts, it is assumed that it provides a better resolution. (for loop)
        uint256 poolTokens = (token0B0 * ts) / _balance0[token0];
        require(minOut <= poolTokens, SWAP_RETURN_INSUFFICIENT);
        _balance0[token0] += token0B0;

        for (uint256 i = 1; i < it; i++) {
            address token = tokens[i];
            // The pool token is used as reference, since it providers a higher resolution
            // than the balance0 constraint.
            _balance0[token] += (_balance0[token] * poolTokens) / ts;
            // Alternative based on balance0 constraint  <- Lower resolution
            // _balance0[token] += (token0B0*_balance0[token])/_balance0[token0]
        }

        // Check if the swap honors the security limit.
        checkAndSetLiquidityCapacity(poolTokens);

        // Mint pool tokens for _who
        _mint(who, poolTokens);

        emit SwapFromLiquidityUnits(who, U, poolTokens, messageHash);

        return poolTokens;
    }
}