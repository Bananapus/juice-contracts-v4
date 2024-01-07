// SOLVED: +++ weird token0/token1 ordering issue -> double-check the terminal
// SOVLED: convert native token to weth address at the begining of the flow, then convert back at the end (only oding it
// once)
// DROPPED: use sqrtPriceLimit (can be based on min amount or coming from frontend) instead of try-catch (flow from bbd,
// not used here)
// TODO: get rid of accept token/transfer in callback/non custodial terminal, even atomically (cf @xBA5ED comment)
// TODO: add price feed to vanilla project
// TODO: use quoter to check if 7% price impact is expected (uni-weth has low liq on Sepolia, so probably is)
// TOdo: if pool out == weth, check if the project terminal accepts weth or eth/native token
// TODO: sweep any leftover
// TODO: natspecs

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IPermit2.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {OracleLibrary} from "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";

import {IJBDirectory} from "./interfaces/IJBDirectory.sol";
import {IJBPermissions} from "./interfaces/IJBPermissions.sol";
import {IJBProjects} from "./interfaces/IJBProjects.sol";
import {IJBTerminalStore} from "./interfaces/IJBTerminalStore.sol";
import {JBMetadataResolver} from "./libraries/JBMetadataResolver.sol";
import {JBSingleAllowanceContext} from "./structs/JBSingleAllowanceContext.sol";
import {JBPermissioned} from "./abstract/JBPermissioned.sol";
import {JBPermissionIds} from "./libraries/JBPermissionIds.sol";
import {JBAccountingContext} from "./structs/JBAccountingContext.sol";
import {JBConstants} from "./libraries/JBConstants.sol";

import {IJBTerminal, IJBPermitTerminal, IJBMultiTerminal} from "./interfaces/terminal/IJBMultiTerminal.sol";

import {IWETH9} from "./interfaces/external/IWETH9.sol";

/// @notice Terminal providing an intermediate layer when receiving a payment in a token without
///         a native terminal deployed. This terminal will swap the token received for a given token,
///         then use the correct terminal to redirect the payment
///
///         user  -- token A --> swap terminal: swap for B -- token B --> target terminal
///          ^                                                                 |
///          |____________project token, NFT, etc______________________________|
///
/// @dev    Slippage is prevented by using a quote passed by the user (using the JBMetadataResolver
///         format, along the address of the pool to use) or a twap from the pool's oracle if no quote
///         is provided (the pool to use *must* then be defined by the project owner).
/// @custom:benediction DEVS BENEDICAT ET PROTEGAT CONTRACTVS MEAM
contract JBSwapTerminal is JBPermissioned, Ownable, IJBTerminal, IJBPermitTerminal, IUniswapV3SwapCallback {
    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // ------------------------------ structs ---------------------------- //
    //*********************************************************************//

    /// @notice  A struct representing the parameters of a swap.
    /// @dev    This struct is only used in memory. The extra cost comes from mstore and related mem expansion, as well
    /// as mload.
    ///         The mem expansion is calculated as follow:
    ///             memory_size_word = (memory_byte_size + 31) / 32
    ///             memory_cost = (memory_size_word ** 2) / 512 + (3 * memory_size_word)

    ///         Given 0 memory reused, ie expansion to pay for every word newly stored, storing the struct being the
    /// first operaton,
    ///         we're starting at initial free mem pointer, 0x80):
    ///             Without packing
    ///                 new msize = 128 + 9
    ///                 mem_cost = 137**2 / 512 + 3 * 137 = 447 units (this should be substracted from the previous
    /// cost, but we just want to compare)
    ///             If packing in 6 words
    ///                 mem_cost = 134**2 / 512 + 3 * 134 = 437 units
    ///             (6 words by downcasting project id to uint96, then pack it with the pool address, then pack
    /// (tokenIn, inIsNativeToken) and (tokenOut, outIsNativeToken))
    ///             We need to pack once (in pay(..)) and adding a mask/shifting at least 6 times (18 units) -> more
    /// expensive than the mem expansion cost
    struct SwapParams {
        uint256 projectId;
        IUniswapV3Pool pool;
        address tokenIn;
        bool inIsNativeToken; // tokenIn is weth if true
        address tokenOut;
        bool outIsNativeToken; // tokenOut is weth if true
        uint256 amountIn;
        uint256 minAmountOut;
    }

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error PERMIT_ALLOWANCE_NOT_ENOUGH();
    error NO_DEFAULT_POOL_DEFINED();
    error NO_MSG_VALUE_ALLOWED();
    error TOKEN_NOT_ACCEPTED();
    error TOKEN_NOT_IN_POOL();
    error UNSUPPORTED();
    error MAX_SLIPPAGE(uint256, uint256);

    //*********************************************************************//
    // --------------------- internal stored constants ------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    mapping(uint256 => uint256) internal _twapParamsOf;

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    uint160 SLIPPAGE_DENOMINATOR = 10_000;

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice Mints ERC-721's that represent project ownership and transfers.
    IJBProjects public immutable PROJECTS;

    /// @notice The directory of terminals and controllers for PROJECTS.
    IJBDirectory public immutable DIRECTORY;

    /// @notice The contract that stores and manages the terminal's data.
    IJBTerminalStore public immutable STORE;

    /// @notice The permit2 utility.
    IPermit2 public immutable PERMIT2;

    /// @notice The wrapper to the native token ("weth" as a generic term).
    IWETH9 public immutable WETH;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    // project ID -> token received -> token to get -> pool to use
    mapping(uint256 => mapping(address => mapping(address => IUniswapV3Pool))) public poolFor;

    // project ID -> token received -> accounting context
    mapping(uint256 => mapping(address => JBAccountingContext)) public accountingContextFor;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    function accountingContextForTokenOf(
        uint256 _projectId,
        address _token
    )
        external
        view
        override
        returns (JBAccountingContext memory)
    {
        return accountingContextFor[_projectId][_token];
    }

    function accountingContextsOf(uint256 _projectId) external view override returns (JBAccountingContext[] memory) {}
    function currentSurplusOf(uint256 projectId, uint256 decimals, uint256 currency) external view returns (uint256) {}

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    ///  _interfaceId The ID of the interface to check for adherance to.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 _interfaceId) public view virtual override returns (bool) {
        return _interfaceId == type(IJBTerminal).interfaceId || _interfaceId == type(IJBPermitTerminal).interfaceId
            || _interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // -------------------------- internal views ------------------------- //
    //*********************************************************************//

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    constructor(
        IJBProjects _projects,
        IJBPermissions _permissions,
        IJBDirectory _directory,
        IPermit2 _permit2,
        address _owner,
        IWETH9 _weth
    )
        JBPermissioned(_permissions)
        Ownable(_owner)
    {
        PROJECTS = _projects;
        DIRECTORY = _directory;
        PERMIT2 = _permit2;
        WETH = _weth;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//
    /// @notice
    ///  _projectId The ID of the project being paid.
    ///  _amount The amount of terminal tokens being received, as a fixed point number with the same amount of decimals
    /// as this terminal. If this terminal's token is ETH, this is ignored and msg.value is used in its place.
    ///  _token The token being paid. This terminal ignores this property since it only manages one token.
    ///  _beneficiary The address to mint tokens for and pass along to the funding cycle's data source and delegate.
    ///  _minReturnedTokens The minimum number of project tokens expected in return, as a fixed point number with the
    /// same amount of decimals as this terminal.
    ///  _memo A memo to pass along to the emitted event.
    ///  _metadata Bytes to send along to the data source, delegate, and emitted event, if provided.
    /// @return The number of tokens minted for the beneficiary, as a fixed point number with 18 decimals.
    function pay(
        uint256 _projectId,
        address _token,
        uint256 _amount,
        address _beneficiary,
        uint256 _minReturnedTokens,
        string calldata _memo,
        bytes calldata _metadata
    )
        external
        payable
        virtual
        override
        returns (uint256)
    {
        SwapParams memory _swapParams;
        _swapParams.projectId = _projectId;

        if (_token == JBConstants.NATIVE_TOKEN) {
            _swapParams.tokenIn = address(WETH);
            _swapParams.inIsNativeToken = true;
            _swapParams.amountIn = msg.value;
        } else {
            _swapParams.tokenIn = _token;
            _swapParams.amountIn = _amount;
        }

        {
            // Check for a quote passed by the user
            (bool _exists, bytes memory _parsedData) = JBMetadataResolver.getDataFor(bytes4("SWAP"), _metadata);

            if (_exists) {
                address _rawTokenOut;
                // If there is a quote, use it
                (_swapParams.minAmountOut, _swapParams.pool, _rawTokenOut) =
                    abi.decode(_parsedData, (uint256, IUniswapV3Pool, address));

                if (_rawTokenOut == JBConstants.NATIVE_TOKEN) {
                    _swapParams.tokenOut = address(WETH);
                    _swapParams.outIsNativeToken = true;
                } else {
                    _swapParams.tokenOut = _rawTokenOut;
                }
            } else {
                // If no quote, check there is a default pool assigned and get a twap
                IUniswapV3Pool _pool = poolFor[_projectId][_token][address(0)];

                _swapParams.pool = _pool;

                // If no default pool, revert
                if (address(_pool) == address(0)) revert NO_DEFAULT_POOL_DEFINED();

                (address _poolToken0, address _poolToken1) = (_pool.token0(), _pool.token1());

                // Uniswap pool aren't using native token, stay false by default
                _swapParams.tokenOut = _poolToken0 == _token ? _poolToken1 : _poolToken0;

                // Get a twap from the pool, includes a default max slippage
                _swapParams.minAmountOut = _getTwapFrom(_swapParams);
            }
        }

        IJBTerminal _terminal = DIRECTORY.primaryTerminalOf(
            _projectId, _swapParams.outIsNativeToken ? JBConstants.NATIVE_TOKEN : _swapParams.tokenOut
        );

        // Check the primary terminal accepts the token (save swap gas if not accepted)
        if (address(_terminal) == address(0)) revert TOKEN_NOT_ACCEPTED();

        _swapParams.amountIn = _acceptFundsFor(_swapParams, _metadata);

        // Swap (will check if we're within the slippage tolerance in the callback))
        uint256 _receivedFromSwap = _swap(_swapParams);

        // Pay on primary terminal, with correct beneficiary (sender or benficiary if passed)
        _terminal.pay{value: _swapParams.outIsNativeToken ? _receivedFromSwap : 0}(
            _swapParams.projectId,
            _swapParams.outIsNativeToken ? JBConstants.NATIVE_TOKEN : _swapParams.tokenOut,
            _receivedFromSwap,
            _beneficiary,
            _minReturnedTokens,
            _memo,
            _metadata
        );

        return _receivedFromSwap;
    }

    function uniswapV3SwapCallback(
        int256 _amount0Delta,
        int256 _amount1Delta,
        bytes calldata _data
    )
        external
        override
    {
        // Unpack the data passed in through the swap hook.
        (address _tokenIn, bool _shouldWrap) = abi.decode(_data, (address, bool));

        // Keep a reference to the amount of tokens that should be sent to fulfill the swap (the positive delta)
        uint256 _amountToSendToPool = _amount0Delta < 0 ? uint256(_amount1Delta) : uint256(_amount0Delta);

        // Wrap ETH into WETH if relevant
        if (_shouldWrap) WETH.deposit{value: _amountToSendToPool}();

        // Transfer the token to the pool.
        // This terminal should NEVER keep token in its balance !!
        IERC20(_tokenIn).transfer(msg.sender, _amountToSendToPool);
    }

    /// @notice prevent ETH from being sent directly to the terminal (only allowed when wrapped, during a swap)
    receive() external payable {
        if (msg.sender != address(WETH)) revert NO_MSG_VALUE_ALLOWED();
    }

    /// @notice
    ///  _projectId The ID of the project to which the funds received belong.
    ///  _amount The amount of tokens to add, as a fixed point number with the same number of decimals as this terminal.
    /// If this is an ETH terminal, this is ignored and msg.value is used instead.
    ///  _token The token being paid. This terminal ignores this property since it only manages one currency.
    ///  _shouldRefundHeldFees A flag indicating if held fees should be refunded based on the amount being added.
    ///  _memo A memo to pass along to the emitted event.
    ///  _metadata Extra data to pass along to the emitted event.
    function addToBalanceOf(
        uint256 _projectId,
        address _token,
        uint256 _amount,
        bool _shouldRefundHeldFees,
        string calldata _memo,
        bytes calldata _metadata
    )
        external
        payable
        virtual
        override
    {
        revert UNSUPPORTED();
    }

    // add a pool to use for a given token in
    function addDefaultPool(uint256 _projectId, address _token, IUniswapV3Pool _pool) external {
        _requirePermissionFrom(PROJECTS.ownerOf(_projectId), _projectId, JBPermissionIds.MODIFY_DEFAULT_POOL);
        poolFor[_projectId][_token][address(0)] = _pool;
        accountingContextFor[_projectId][_token] = JBAccountingContext({
            token: _token,
            decimals: IERC20Metadata(_token).decimals(),
            currency: uint32(uint160(_token))
        });
    }

    function addAccountingContextsFor(uint256 projectId, address[] calldata tokens) external {}

    function addTwapParamsFor(uint256 _projectId, uint32 _quotePeriod, uint160 _maxDelta) external {
        _requirePermissionFrom(PROJECTS.ownerOf(_projectId), _projectId, JBPermissionIds.MODIFY_TWAP_PARAMS);
        _twapParamsOf[_projectId] = uint256(_quotePeriod | uint256(_maxDelta) << 32);
    }

    function migrateBalanceOf(uint256 projectId, address token, IJBTerminal to) external returns (uint256 balance) {}

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Get a quote based on TWAP over a secondsAgo period, taking into account a twapDelta max deviation.
    ///  _projectId The ID of the project for which the swap is being made.
    ///  _projectToken The project's token being swapped for.
    ///  _amountIn The amount being used to swap.
    ///  _terminalToken The token paid in being used to swap.
    /// @return minSqrtPriceX96 the minimum price accepted
    function _getTwapFrom(SwapParams memory _swapParams) internal view returns (uint160) {
        // Unpack the TWAP params and get a reference to the period and slippage.
        uint256 _twapParams = _twapParamsOf[_swapParams.projectId];
        uint32 _quotePeriod = uint32(_twapParams);
        uint160 _maxDelta = uint160(_twapParams >> 32);

        // Keep a reference to the TWAP tick.
        (int24 _arithmeticMeanTick,) = OracleLibrary.consult(address(_swapParams.pool), _quotePeriod);

        // Get a quote based on this TWAP tick.
        uint160 _sqrtPriceX96 = TickMath.getSqrtRatioAtTick(_arithmeticMeanTick);

        // Return the lowest TWAP tolerable.
        _swapParams.tokenIn < _swapParams.tokenOut
            ? _sqrtPriceX96 - (_sqrtPriceX96 * _maxDelta) / SLIPPAGE_DENOMINATOR
            : _sqrtPriceX96 + (_sqrtPriceX96 * _maxDelta) / SLIPPAGE_DENOMINATOR;
    }

    /// @notice Accepts an incoming token.
    ///  _projectId The ID of the project for which the transfer is being accepted.
    ///  _token The token being accepted.
    ///  _amount The amount of tokens being accepted.
    ///  _metadata The metadata in which permit2 context is provided.
    /// @return amount The amount of tokens that have been accepted.
    function _acceptFundsFor(SwapParams memory _swapParams, bytes calldata _metadata) internal returns (uint256) {
        address _token = _swapParams.tokenIn;

        // Make sure the project has set an accounting context for the token being paid.
        // if (_accountingContextForTokenOf[_projectId][_token].token == address(0)) {
        //     revert TOKEN_NOT_ACCEPTED();
        // }

        // If the terminal's token is ETH, override `_amount` with msg.value.
        if (_token == JBConstants.NATIVE_TOKEN) return msg.value;

        // Amount must be greater than 0.
        if (msg.value != 0) revert NO_MSG_VALUE_ALLOWED();

        // Unpack the allowance to use, if any, given by the frontend.
        (bool _exists, bytes memory _parsedMetadata) =
            JBMetadataResolver.getDataFor(bytes4(uint32(uint160(address(this)))), _metadata);

        // Check if the metadata contained permit data.
        if (_exists) {
            // Keep a reference to the allowance context parsed from the metadata.
            (JBSingleAllowanceContext memory _allowance) = abi.decode(_parsedMetadata, (JBSingleAllowanceContext));

            // Make sure the permit allowance is enough for this payment. If not we revert early.
            if (_allowance.amount < _swapParams.amountIn) {
                revert PERMIT_ALLOWANCE_NOT_ENOUGH();
            }

            // Set the allowance to `spend` tokens for the user.
            _permitAllowance(_allowance, _token);
        }

        // Get a reference to the balance before receiving tokens.
        uint256 _balanceBefore = IERC20(_token).balanceOf(address(this));

        // Transfer tokens to this terminal from the msg sender.
        _transferFor(msg.sender, payable(address(this)), _token, _swapParams.amountIn);

        // The amount should reflect the change in balance.
        return IERC20(_token).balanceOf(address(this)) - _balanceBefore;
    }

    function _swap(SwapParams memory _swapParams) internal returns (uint256 amountReceived) {
        address _tokenIn = _swapParams.tokenIn;
        address _tokenOut = _swapParams.tokenOut;
        bool zeroForOne = _tokenIn < _tokenOut;

        (int256 amount0, int256 amount1) = _swapParams.pool.swap({
            recipient: address(this),
            zeroForOne: zeroForOne,
            amountSpecified: int256(_swapParams.amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            data: abi.encode(_tokenIn, _swapParams.inIsNativeToken)
        });

        amountReceived = uint256(-(zeroForOne ? amount1 : amount0));

        if (amountReceived < _swapParams.minAmountOut) revert MAX_SLIPPAGE(amountReceived, _swapParams.minAmountOut);

        // Unwrap weth if needed
        if (_swapParams.outIsNativeToken) WETH.withdraw(amountReceived);
    }

    /// @notice Reverts an expected payout.
    ///  _projectId The ID of the project having paying out.
    ///  _token The address of the token having its transfer reverted.
    ///  _expectedDestination The address the payout was expected to go to.
    ///  _allowanceAmount The amount that the destination has been allowed to use.
    ///  _depositAmount The amount of the payout as debited from the project's balance.
    function _revertTransferFrom(
        uint256 _projectId,
        address _token,
        address _expectedDestination,
        uint256 _allowanceAmount,
        uint256 _depositAmount
    )
        internal
    {
        // Cancel allowance if needed.
        if (_allowanceAmount != 0 && _token != JBConstants.NATIVE_TOKEN) {
            IERC20(_token).safeDecreaseAllowance(_expectedDestination, _allowanceAmount);
        }

        // Add undistributed amount back to project's balance.
        STORE.recordAddedBalanceFor(_projectId, _token, _depositAmount);
    }

    /// @notice Transfers tokens.
    ///  _from The address from which the transfer should originate.
    ///  _to The address to which the transfer should go.
    ///  _token The token being transfered.
    ///  _amount The amount of the transfer, as a fixed point number with the same number of decimals as this terminal.
    function _transferFor(address _from, address payable _to, address _token, uint256 _amount) internal virtual {
        // If the token is ETH, assume the native token standard.
        if (_token == JBConstants.NATIVE_TOKEN) return Address.sendValue(_to, _amount);

        if (_from == address(this)) {
            return IERC20(_token).safeTransfer(_to, _amount);
        }

        // If there's sufficient approval, transfer normally.
        if (IERC20(_token).allowance(address(_from), address(this)) >= _amount) {
            return IERC20(_token).safeTransferFrom(_from, _to, _amount);
        }

        // Otherwise we attempt to use the PERMIT2 method.
        PERMIT2.transferFrom(_from, _to, uint160(_amount), _token);
    }

    /// @notice Logic to be triggered before transferring tokens from this terminal.
    ///  _to The address to which the transfer is going.
    ///  _token The token being transfered.
    ///  _amount The amount of the transfer, as a fixed point number with the same number of decimals as this terminal.
    function _beforeTransferFor(address _to, address _token, uint256 _amount) internal virtual {
        // If the token is ETH, assume the native token standard.
        if (_token == JBConstants.NATIVE_TOKEN) return;
        IERC20(_token).safeIncreaseAllowance(_to, _amount);
    }

    /// @notice Sets the permit2 allowance for a token.
    ///  _allowance the allowance to get using permit2
    ///  _token The token being allowed.
    function _permitAllowance(JBSingleAllowanceContext memory _allowance, address _token) internal {
        PERMIT2.permit(
            msg.sender,
            IAllowanceTransfer.PermitSingle({
                details: IAllowanceTransfer.PermitDetails({
                    token: _token,
                    amount: _allowance.amount,
                    expiration: _allowance.expiration,
                    nonce: _allowance.nonce
                }),
                spender: address(this),
                sigDeadline: _allowance.sigDeadline
            }),
            _allowance.signature
        );
    }
}
