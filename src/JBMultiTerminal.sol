// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {Context} from "lib/openzeppelin-contracts/contracts/utils/Context.sol";
import {IERC165} from "lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC2771Context} from "lib/openzeppelin-contracts/contracts/metatx/ERC2771Context.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC165Checker} from "lib/openzeppelin-contracts/contracts/utils/introspection/ERC165Checker.sol";
import {mulDiv} from "lib/prb-math/src/Common.sol";
import {IPermit2} from "lib/permit2/src/interfaces/IPermit2.sol";
import {IAllowanceTransfer} from "lib/permit2/src/interfaces/IPermit2.sol";
import {IJBController} from "./interfaces/IJBController.sol";
import {IJBDirectory} from "./interfaces/IJBDirectory.sol";
import {IJBFeelessAddresses} from "./interfaces/IJBFeelessAddresses.sol";
import {IJBSplits} from "./interfaces/IJBSplits.sol";
import {IJBPermissioned} from "./interfaces/IJBPermissioned.sol";
import {IJBPermissions} from "./interfaces/IJBPermissions.sol";
import {IJBProjects} from "./interfaces/IJBProjects.sol";
import {IJBTerminalStore} from "./interfaces/IJBTerminalStore.sol";
import {IJBSplitHook} from "./interfaces/IJBSplitHook.sol";
import {JBConstants} from "./libraries/JBConstants.sol";
import {JBFees} from "./libraries/JBFees.sol";
import {JBRulesetMetadataResolver} from "./libraries/JBRulesetMetadataResolver.sol";
import {JBMetadataResolver} from "./libraries/JBMetadataResolver.sol";
import {JBPermissionIds} from "./libraries/JBPermissionIds.sol";
import {JBAfterRedeemRecordedContext} from "./structs/JBAfterRedeemRecordedContext.sol";
import {JBAfterPayRecordedContext} from "./structs/JBAfterPayRecordedContext.sol";
import {JBFee} from "./structs/JBFee.sol";
import {JBRuleset} from "./structs/JBRuleset.sol";
import {JBPayHookSpecification} from "./structs/JBPayHookSpecification.sol";
import {JBRedeemHookSpecification} from "./structs/JBRedeemHookSpecification.sol";
import {JBSingleAllowanceContext} from "./structs/JBSingleAllowanceContext.sol";
import {JBSplit} from "./structs/JBSplit.sol";
import {JBSplitHookContext} from "./structs/JBSplitHookContext.sol";
import {JBAccountingContext} from "./structs/JBAccountingContext.sol";
import {JBTokenAmount} from "./structs/JBTokenAmount.sol";
import {JBPermissioned} from "./abstract/JBPermissioned.sol";
import {IJBMultiTerminal} from "./interfaces/terminal/IJBMultiTerminal.sol";
import {IJBFeeTerminal} from "./interfaces/terminal/IJBFeeTerminal.sol";
import {IJBTerminal} from "./interfaces/terminal/IJBTerminal.sol";
import {IJBRedeemTerminal} from "./interfaces/terminal/IJBRedeemTerminal.sol";
import {IJBPayoutTerminal} from "./interfaces/terminal/IJBPayoutTerminal.sol";
import {IJBPermitTerminal} from "./interfaces/terminal/IJBPermitTerminal.sol";

/// @notice Generic terminal managing inflows and outflows of funds into the protocol ecosystem.
contract JBMultiTerminal is JBPermissioned, ERC2771Context, IJBMultiTerminal {
    // A library that parses the packed ruleset metadata into a friendlier format.
    using JBRulesetMetadataResolver for JBRuleset;

    // A library that adds default safety checks to ERC20 functionality.
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error ACCOUNTING_CONTEXT_ALREADY_SET();
    error INADEQUATE_PAYOUT_AMOUNT();
    error INADEQUATE_RECLAIM_AMOUNT();
    error UNDER_MIN_RETURNED_TOKENS();
    error NO_MSG_VALUE_ALLOWED();
    error OVERFLOW_ALERT();
    error PERMIT_ALLOWANCE_NOT_ENOUGH();
    error TERMINAL_TOKENS_INCOMPATIBLE();
    error TOKEN_NOT_ACCEPTED();

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice The fee percent (out of `JBConstants.MAX_FEE`).
    /// @dev Fees are charged on payouts to addresses, when the surplus allowance is used, and on redemptions where the
    /// redemption rate is less than 100%.
    uint256 public constant override FEE = 25; // 2.5%

    //*********************************************************************//
    // ------------------------ private constants ------------------------ //
    //*********************************************************************//

    /// @notice The ID of the project which receives fees is 1, as it should be the first project launched during the
    /// deployment process.
    uint256 private constant _FEE_BENEFICIARY_PROJECT_ID = 1;

    /// @notice 28 days, the number of seconds a fee can be held for.
    uint256 private constant _FEE_HOLDING_SECONDS = 2_419_200;

    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    IJBProjects public immutable override PROJECTS;

    /// @notice The directory of terminals and controllers for PROJECTS.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The contract that stores splits for each project.
    IJBSplits public immutable override SPLITS;

    /// @notice The contract that stores and manages the terminal's data.
    IJBTerminalStore public immutable override STORE;

    /// @notice The contract that stores addresses that shouldn't incur fees when being paid towards or from.
    IJBFeelessAddresses public immutable override FEELESS_ADDRESSES;

    /// @notice The permit2 utility.
    IPermit2 public immutable override PERMIT2;

    //*********************************************************************//
    // --------------------- private stored properties ------------------- //
    //*********************************************************************//

    /// @notice Context describing how a token is accounted for by a project.
    /// @custom:param projectId The ID of the project that the token accounting context applies to.
    /// @custom:param token The address of the token being accounted for.
    mapping(uint256 projectId => mapping(address token => JBAccountingContext)) private _accountingContextForTokenOf;

    /// @notice A list of tokens accepted by each project.
    /// @custom:param projectId The ID of the project to get a list of accepted tokens for.
    mapping(uint256 projectId => JBAccountingContext[]) private _accountingContextsOf;

    /// @notice Fees that are being held for each project.
    /// @dev Projects can temporarily hold fees and unlock them later by adding funds to the project's balance.
    /// @dev Held fees can be processed at any time by this terminal's owner.
    /// @custom:param projectId The ID of the project that is holding fees.
    /// @custom:param token The token that the fees are held in.
    mapping(uint256 projectId => mapping(address token => JBFee[])) private _heldFeesOf;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice A project's accounting context for a token.
    /// @dev See the `JBAccountingContext` struct for more information.
    /// @param projectId The ID of the project to get token accounting context of.
    /// @param token The token to check the accounting context of.
    /// @return The token's accounting context for the token.
    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    )
        external
        view
        override
        returns (JBAccountingContext memory)
    {
        return _accountingContextForTokenOf[projectId][token];
    }

    /// @notice The tokens accepted by a project.
    /// @param projectId The ID of the project to get the accepted tokens of.
    /// @return tokenContexts The accounting contexts of the accepted tokens.
    function accountingContextsOf(uint256 projectId) external view override returns (JBAccountingContext[] memory) {
        return _accountingContextsOf[projectId];
    }

    /// @notice Gets the total current surplus amount in this terminal for a project, in terms of a given currency.
    /// @dev This total surplus only includes tokens that the project accepts (as returned by
    /// `accountingContextsOf(...)`).
    /// @param projectId The ID of the project to get the current total surplus of.
    /// @param decimals The number of decimals to include in the fixed point returned value.
    /// @param currency The currency to express the returned value in terms of.
    /// @return The current surplus amount the project has in this terminal, in terms of `currency` and with the
    /// specified number of decimals.
    function currentSurplusOf(
        uint256 projectId,
        uint256 decimals,
        uint256 currency
    )
        external
        view
        virtual
        override
        returns (uint256)
    {
        return STORE.currentSurplusOf(address(this), projectId, _accountingContextsOf[projectId], decimals, currency);
    }

    /// @notice Fees that are being held for a project.
    /// @dev Projects can temporarily hold fees and unlock them later by adding funds to the project's balance.
    /// @dev Held fees can be processed at any time by this terminal's owner.
    /// @param projectId The ID of the project that is holding fees.
    /// @param token The token that the fees are held in.
    function heldFeesOf(uint256 projectId, address token) external view override returns (JBFee[] memory) {
        return _heldFeesOf[projectId][token];
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param interfaceId The ID of the interface to check for adherance to.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IJBMultiTerminal).interfaceId || interfaceId == type(IJBPermissioned).interfaceId
            || interfaceId == type(IJBTerminal).interfaceId || interfaceId == type(IJBRedeemTerminal).interfaceId
            || interfaceId == type(IJBPayoutTerminal).interfaceId || interfaceId == type(IJBPermitTerminal).interfaceId
            || interfaceId == type(IJBMultiTerminal).interfaceId || interfaceId == type(IJBFeeTerminal).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //*********************************************************************//
    // -------------------------- private views -------------------------- //
    //*********************************************************************//

    /// @notice Checks this terminal's balance of a specific token.
    /// @param token The address of the token to get this terminal's balance of.
    /// @return This terminal's balance.
    function _balance(address token) private view returns (uint256) {
        // If the `token` is native, get the native token balance.
        return token == JBConstants.NATIVE_TOKEN ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param permissions A contract storing permissions.
    /// @param projects A contract which mints ERC-721s that represent project ownership and transfers.
    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param splits A contract that stores splits for each project.
    /// @param store A contract that stores the terminal's data.
    /// @param feelessAddresses A contract that stores addresses that shouldn't incur fees when being paid towards or
    /// from.
    /// @param permit2 A permit2 utility.
    constructor(
        IJBPermissions permissions,
        IJBProjects projects,
        IJBDirectory directory,
        IJBSplits splits,
        IJBTerminalStore store,
        IJBFeelessAddresses feelessAddresses,
        IPermit2 permit2,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
    {
        PROJECTS = projects;
        DIRECTORY = directory;
        SPLITS = splits;
        STORE = store;
        FEELESS_ADDRESSES = feelessAddresses;
        PERMIT2 = permit2;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Pay a project with tokens.
    /// @param projectId The ID of the project being paid.
    /// @param amount The amount of terminal tokens being received, as a fixed point number with the same number of
    /// decimals as this terminal. If this terminal's token is native, this is ignored and `msg.value` is used in its
    /// place.
    /// @param token The token being paid.
    /// @param beneficiary The address to mint tokens to, and pass along to the ruleset's data hook and pay hook if
    /// applicable.
    /// @param minReturnedTokens The minimum number of project tokens expected in return for this payment, as a fixed
    /// point number with the same number of decimals as this terminal. If the amount of tokens minted for the
    /// beneficiary would be less than this amount, the payment is reverted.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes to pass along to the emitted event, as well as the data hook and pay hook if applicable.
    /// @return beneficiaryTokenCount The number of tokens minted to the beneficiary, as a fixed point number with 18
    /// decimals.
    function pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        uint256 minReturnedTokens,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        virtual
        override
        returns (uint256 beneficiaryTokenCount)
    {
        // Pay the project.
        beneficiaryTokenCount = _pay({
            projectId: projectId,
            token: token,
            amount: _acceptFundsFor(projectId, token, amount, metadata),
            payer: _msgSender(),
            beneficiary: beneficiary,
            memo: memo,
            metadata: metadata
        });

        // The token count for the beneficiary must be greater than or equal to the specified minimum.
        if (beneficiaryTokenCount < minReturnedTokens) {
            revert UNDER_MIN_RETURNED_TOKENS();
        }
    }

    /// @notice Adds funds to a project's balance without minting tokens.
    /// @dev Adding to balance can unlock held fees if `shouldUnlockHeldFees` is true.
    /// @param projectId The ID of the project to add funds to the balance of.
    /// @param amount The amount of tokens to add to the balance, as a fixed point number with the same number of
    /// decimals as this terminal. If this is a native token terminal, this is ignored and `msg.value` is used instead.
    /// @param token The token being added to the balance.
    /// @param shouldReturnHeldFees A flag indicating if held fees should be returned based on the amount being added.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Extra data to pass along to the emitted event.
    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool shouldReturnHeldFees,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable
        virtual
        override
    {
        // Add to balance.
        _addToBalanceOf({
            projectId: projectId,
            token: token,
            amount: _acceptFundsFor(projectId, token, amount, metadata),
            shouldReturnHeldFees: shouldReturnHeldFees,
            memo: memo,
            metadata: metadata
        });
    }

    /// @notice Holders can redeem a project's tokens to reclaim some of that project's surplus tokens, or to trigger
    /// rules determined by the current ruleset's data hook and redeem hook.
    /// @dev Only a token's holder or an operator with the `REDEEM_TOKENS` permission from that holder can redeem those
    /// tokens.
    /// @param holder The account whose tokens are being redeemed.
    /// @param projectId The ID of the project the project tokens belong to.
    /// @param tokenToReclaim The token being reclaimed.
    /// @param redeemCount The number of project tokens to redeem, as a fixed point number with 18 decimals.
    /// @param minTokensReclaimed The minimum number of terminal tokens expected in return, as a fixed point number with
    /// the same number of decimals as this terminal. If the amount of tokens minted for the beneficiary would be less
    /// than this amount, the redemption is reverted.
    /// @param beneficiary The address to send the reclaimed terminal tokens to, and to pass along to the ruleset's
    /// data hook and redeem hook if applicable.
    /// @param metadata Bytes to send along to the emitted event, as well as the data hook and redeem hook if
    /// applicable.
    /// @return reclaimAmount The amount of terminal tokens that the project tokens were redeemed for, as a fixed point
    /// number with 18 decimals.
    function redeemTokensOf(
        address holder,
        uint256 projectId,
        address tokenToReclaim,
        uint256 redeemCount,
        uint256 minTokensReclaimed,
        address payable beneficiary,
        bytes calldata metadata
    )
        external
        virtual
        override
        returns (uint256 reclaimAmount)
    {
        // Enforce permissions.
        _requirePermissionFrom({account: holder, projectId: projectId, permissionId: JBPermissionIds.REDEEM_TOKENS});

        reclaimAmount = _redeemTokensOf(holder, projectId, tokenToReclaim, redeemCount, beneficiary, metadata);

        // The amount being reclaimed must be at least as much as was expected.
        if (reclaimAmount < minTokensReclaimed) revert INADEQUATE_RECLAIM_AMOUNT();
    }

    /// @notice Sends payouts to a project's current payout split group, according to its ruleset, up to its current
    /// payout limit.
    /// @dev If the percentages of the splits in the project's payout split group do not add up to 100%, the remainder
    /// is sent to the project's owner.
    /// @dev Anyone can send payouts on a project's behalf. Projects can include a wildcard split (a split with no
    /// `hook`, `projectId`, or `beneficiary`) to send funds to the `_msgSender()` which calls this function. This can
    /// be used to incentivize calling this function.
    /// @dev payouts sent to addresses which aren't feeless incur the protocol fee.
    /// @dev Payouts a projects don't incur fees if its terminal is feeless.
    /// @param projectId The ID of the project having its payouts sent.
    /// @param token The token being sent.
    /// @param amount The total number of terminal tokens to send, as a fixed point number with same number of decimals
    /// as this terminal.
    /// @param currency The expected currency of the payouts being sent. Must match the currency of one of the
    /// project's current ruleset's payout limits.
    /// @param minTokensPaidOut The minimum number of terminal tokens that the `amount` should be worth (if expressed
    /// in terms of this terminal's currency), as a fixed point number with the same number of decimals as this
    /// terminal. If the amount of tokens paid out would be less than this amount, the send is reverted.
    /// @return amountPaidOut The total amount paid out.
    function sendPayoutsOf(
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 currency,
        uint256 minTokensPaidOut
    )
        external
        virtual
        override
        returns (uint256 amountPaidOut)
    {
        amountPaidOut = _sendPayoutsOf(projectId, token, amount, currency);

        // The amount being paid out must be at least as much as was expected.
        if (amountPaidOut < minTokensPaidOut) revert INADEQUATE_PAYOUT_AMOUNT();
    }

    /// @notice Allows a project to pay out funds from its surplus up to the current surplus allowance.
    /// @dev Only a project's owner or an operator with the `USE_ALLOWANCE` permission from that owner can use the
    /// surplus allowance.
    /// @dev Incurs the protocol fee unless the caller is a feeless address.
    /// @param projectId The ID of the project to use the surplus allowance of.
    /// @param token The token being paid out from the surplus.
    /// @param amount The amount of terminal tokens to use from the project's current surplus allowance, as a fixed
    /// point number with the same amount of decimals as this terminal.
    /// @param currency The expected currency of the amount being paid out. Must match the currency of one of the
    /// project's current ruleset's surplus allowances.
    /// @param minTokensPaidOut The minimum number of terminal tokens that should be used from the surplus allowance
    /// (including fees), as a fixed point number with 18 decimals. If the amount of surplus used would be less than
    /// this amount, the transaction is reverted.
    /// @param beneficiary The address to send the surplus funds to.
    /// @param memo A memo to pass along to the emitted event.
    /// @return amountPaidOut The number of tokens that were sent to the beneficiary, as a fixed point number with
    /// the same amount of decimals as the terminal.
    function useAllowanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 currency,
        uint256 minTokensPaidOut,
        address payable beneficiary,
        string calldata memo
    )
        external
        virtual
        override
        returns (uint256 amountPaidOut)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.USE_ALLOWANCE
        });

        amountPaidOut = _useAllowanceOf(projectId, token, amount, currency, beneficiary, memo);

        // The amount being withdrawn must be at least as much as was expected.
        if (amountPaidOut < minTokensPaidOut) revert INADEQUATE_PAYOUT_AMOUNT();
    }

    /// @notice Migrate a project's funds and operations to a new terminal that accepts the same token type.
    /// @dev Only a project's owner or an operator with the `MIGRATE_TERMINAL` permission from that owner can migrate
    /// the project's terminal.
    /// @param projectId The ID of the project being migrated.
    /// @param token The address of the token being migrated.
    /// @param to The terminal contract being migrated to, which will receive the project's funds and operations.
    /// @return balance The amount of funds that were migrated, as a fixed point number with the same amount of decimals
    /// as this terminal.
    function migrateBalanceOf(
        uint256 projectId,
        address token,
        IJBTerminal to
    )
        external
        virtual
        override
        returns (uint256 balance)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.MIGRATE_TERMINAL
        });

        // The terminal being migrated to must accept the same token as this terminal.
        if (to.accountingContextForTokenOf(projectId, token).decimals == 0) {
            revert TERMINAL_TOKENS_INCOMPATIBLE();
        }

        // Process any held fees.
        _processHeldFeesOf({projectId: projectId, token: token, forced: true});

        // Record the migration in the store.
        balance = STORE.recordTerminalMigration(projectId, token);

        // Transfer the balance if needed.
        if (balance != 0) {
            // Trigger any inherited pre-transfer logic.
            _beforeTransferTo({to: address(to), token: token, amount: balance});

            // If this terminal's token is the native token, send it in `msg.value`.
            uint256 payValue = token == JBConstants.NATIVE_TOKEN ? balance : 0;

            // Withdraw the balance to transfer to the new terminal;
            to.addToBalanceOf{value: payValue}({
                projectId: projectId,
                token: token,
                amount: balance,
                shouldReturnHeldFees: false,
                memo: "",
                metadata: bytes("")
            });
        }

        emit MigrateTerminal(projectId, token, to, balance, _msgSender());
    }

    /// @notice Process any fees that are being held for the project.
    /// @param projectId The ID of the project to process held fees for.
    /// @param token The token to process held fees for.
    function processHeldFeesOf(uint256 projectId, address token) external virtual override {
        _processHeldFeesOf({projectId: projectId, token: token, forced: false});
    }

    /// @notice Adds accounting contexts for a project to this terminal so the project can begin accepting the tokens in
    /// those contexts.
    /// @dev Only a project's owner, an operator with the `SET_ACCOUNTING_CONTEXT` permission from that owner, or a
    /// project's controller can add accounting contexts for the project.
    /// @param projectId The ID of the project having to add accounting contexts for.
    /// @param tokens The tokens to add accounting contexts for.
    function addAccountingContextsFor(uint256 projectId, address[] calldata tokens) external override {
        // Enforce permissions.
        _requirePermissionAllowingOverrideFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_ACCOUNTING_CONTEXT,
            alsoGrantAccessIf: _msgSender() == address(DIRECTORY.controllerOf(projectId))
        });

        // Keep a reference to the number of accounting contexts to add.
        uint256 numberOfAccountingContexts = tokens.length;

        // Keep a reference to the token being iterated on.
        address token;

        // Start accepting each token.
        for (uint256 i; i < numberOfAccountingContexts; i++) {
            // Set the accounting context being iterated on.
            token = tokens[i];

            // Get a storage reference to the currency accounting context for the token.
            JBAccountingContext storage accountingContext = _accountingContextForTokenOf[projectId][token];

            // Make sure the token accounting context isn't already set.
            if (accountingContext.token != address(0)) revert ACCOUNTING_CONTEXT_ALREADY_SET();

            // Define the context from the config.
            accountingContext.token = token;
            accountingContext.decimals = token == JBConstants.NATIVE_TOKEN ? 18 : IERC20Metadata(token).decimals();
            accountingContext.currency = uint32(uint160(token)); // Use the last 4 bytes of the address as the currency.

            // Add the token to the list of accepted tokens of the project.
            _accountingContextsOf[projectId].push(accountingContext);

            emit SetAccountingContext(projectId, token, accountingContext, _msgSender());
        }
    }

    /// @notice Process a specified amount of fees for a project.
    /// @dev Only accepts calls from this terminal itself.
    /// @param projectId The ID of the project paying the fee.
    /// @param token The token the fee is being paid in.
    /// @param amount The fee amount, as a fixed point number with 18 decimals.
    /// @param beneficiary The address to mint tokens to (from the project which receives fees), and pass along to the
    /// ruleset's data hook and pay hook if applicable.
    /// @param feeTerminal The terminal that'll receive the fees.
    function executeProcessFee(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        IJBTerminal feeTerminal
    )
        external
    {
        // NOTICE: May only be called by this terminal itself.
        require(msg.sender == address(this));

        if (address(feeTerminal) == address(0)) {
            revert("404_1");
        }

        // Trigger any inherited pre-transfer logic if funds will be transferred.
        if (address(feeTerminal) != address(this)) {
            _beforeTransferTo({to: address(feeTerminal), token: token, amount: amount});
        }

        // Send the projectId in the metadata.
        bytes memory metadata = bytes(abi.encodePacked(projectId));

        // Call the internal method of the same terminal is being used.
        if (feeTerminal == IJBTerminal(address(this))) {
            _pay({
                projectId: _FEE_BENEFICIARY_PROJECT_ID,
                token: token,
                amount: amount,
                payer: address(this),
                beneficiary: beneficiary,
                memo: "",
                metadata: metadata
            });
        } else {
            // Keep a reference to the amount that'll be paid in.
            uint256 payValue = token == JBConstants.NATIVE_TOKEN ? amount : 0;
            // Send the fee.
            // If this terminal's token is ETH, send it in msg.value.
            feeTerminal.pay{value: payValue}({
                projectId: _FEE_BENEFICIARY_PROJECT_ID,
                token: token,
                amount: amount,
                beneficiary: beneficiary,
                minReturnedTokens: 0,
                memo: "",
                metadata: metadata
            });
        }
    }

    /// @notice Executes a payout to a split.
    /// @dev Only accepts calls from this terminal itself.
    /// @param split The split to pay.
    /// @param projectId The ID of the project the split belongs to.
    /// @param token The address of the token being paid to the split.
    /// @param amount The total amount being paid to the split, as a fixed point number with the same number of
    /// decimals as this terminal.
    /// @return netPayoutAmount The amount sent to the split after subtracting fees.
    function executePayout(
        JBSplit calldata split,
        uint256 projectId,
        address token,
        uint256 amount,
        address originalMessageSender
    )
        external
        returns (uint256 netPayoutAmount)
    {
        // NOTICE: May only be called by this terminal itself.
        require(msg.sender == address(this));

        // By default, the net payout amount is the full amount. This will be adjusted if fees are taken.
        netPayoutAmount = amount;

        // If there's a split hook set, transfer to its `process` function.
        if (split.hook != IJBSplitHook(address(0))) {
            // This payout is eligible for a fee since the funds are leaving this contract and the split hook isn't a
            // feeless address.
            if (!FEELESS_ADDRESSES.isFeeless(address(split.hook))) {
                netPayoutAmount -= JBFees.feeAmountIn(amount, FEE);
            }

            // Create the context to send to the split hook.
            JBSplitHookContext memory context = JBSplitHookContext({
                token: token,
                amount: netPayoutAmount,
                decimals: _accountingContextForTokenOf[projectId][token].decimals,
                projectId: projectId,
                groupId: uint256(uint160(token)),
                split: split
            });

            // Make sure that the address supports the split hook interface.
            if (ERC165Checker.supportsInterface(address(split.hook), type(IJBSplitHook).interfaceId)) {
                revert("400_1");
            }

            // Trigger any inherited pre-transfer logic.
            _beforeTransferTo({to: address(split.hook), token: token, amount: netPayoutAmount});

            // Get a reference to the amount being paid in `msg.value`.
            uint256 payValue = token == JBConstants.NATIVE_TOKEN ? netPayoutAmount : 0;

            // If this terminal's token is the native token, send it in `msg.value`.
            split.hook.processSplitWith{value: payValue}(context);

            // Otherwise, if a project is specified, make a payment to it.
        } else if (split.projectId != 0) {
            // Get a reference to the terminal being used.
            IJBTerminal terminal = DIRECTORY.primaryTerminalOf(split.projectId, token);

            // The project must have a terminal to send funds to.
            if (terminal == IJBTerminal(address(0))) revert("404_2");

            // This payout is eligible for a fee if the funds are leaving this contract and the receiving terminal isn't
            // a feelss address.
            if (terminal != this && !FEELESS_ADDRESSES.isFeeless(address(terminal))) {
                netPayoutAmount -= JBFees.feeAmountIn(amount, FEE);
            }

            // Trigger any inherited pre-transfer logic.
            _beforeTransferTo({to: address(terminal), token: token, amount: netPayoutAmount});

            // Send the `projectId` in the metadata as a referral.
            bytes memory metadata = bytes(abi.encodePacked(projectId));

            // Add to balance if preferred.
            if (split.preferAddToBalance) {
                // Call the internal method if this terminal is being used.
                if (terminal == IJBTerminal(address(this))) {
                    _addToBalanceOf({
                        projectId: split.projectId,
                        token: token,
                        amount: netPayoutAmount,
                        shouldReturnHeldFees: false,
                        memo: "",
                        metadata: metadata
                    });
                } else {
                    // Get a reference to the amount being added to balance through `msg.value`.
                    uint256 payValue = token == JBConstants.NATIVE_TOKEN ? netPayoutAmount : 0;

                    // Add to balance.
                    // If this terminal's token is the native token, send it in `msg.value`.
                    terminal.addToBalanceOf{value: payValue}({
                        projectId: split.projectId,
                        token: token,
                        amount: netPayoutAmount,
                        shouldReturnHeldFees: false,
                        memo: "",
                        metadata: metadata
                    });
                }
            } else {
                // Keep a reference to the beneficiary of the payment.
                address beneficiary = split.beneficiary != address(0) ? split.beneficiary : originalMessageSender;

                // Call the internal pay method if this terminal is being used.
                if (terminal == IJBTerminal(address(this))) {
                    _pay({
                        projectId: split.projectId,
                        token: token,
                        amount: netPayoutAmount,
                        payer: address(this),
                        beneficiary: beneficiary,
                        memo: "",
                        metadata: metadata
                    });
                } else {
                    // Keep a reference to the amount being paid through `msg.value`.
                    uint256 payValue = token == JBConstants.NATIVE_TOKEN ? netPayoutAmount : 0;

                    // Make the payment.
                    // If this terminal's token is the native token, send it in `msg.value`.
                    terminal.pay{value: payValue}({
                        projectId: split.projectId,
                        token: token,
                        amount: netPayoutAmount,
                        beneficiary: beneficiary,
                        minReturnedTokens: 0,
                        memo: "",
                        metadata: metadata
                    });
                }
            }
        } else {
            // If there's a beneficiary, send the funds directly to the beneficiary.
            // If there isn't a beneficiary, send the funds to the  `_msgSender()`.
            address payable recipient =
                split.beneficiary != address(0) ? split.beneficiary : payable(originalMessageSender);

            // This payout is eligible for a fee since the funds are leaving this contract and the recipient isn't a
            // feeless address.
            if (!FEELESS_ADDRESSES.isFeeless(recipient)) {
                netPayoutAmount -= JBFees.feeAmountIn(amount, FEE);
            }

            // If there's a beneficiary, send the funds directly to the beneficiary. Otherwise send to the
            // `_msgSender()`.
            _transferFrom({from: address(this), to: recipient, token: token, amount: netPayoutAmount});
        }
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Returns the sender, prefered to use over `msg.sender`
    /// @return sender the sender address of this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    /// @notice Returns the calldata, prefered to use over `msg.data`
    /// @return calldata the `msg.data` of this call
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @dev ERC-2771 specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view virtual override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    //*********************************************************************//
    // ---------------------- private transactions ----------------------- //
    //*********************************************************************//

    /// @notice Accepts an incoming token.
    /// @param projectId The ID of the project that the transfer is being accepted for.
    /// @param token The token being accepted.
    /// @param amount The number of tokens being accepted.
    /// @param metadata The metadata in which permit2 context is provided.
    /// @return amount The number of tokens which have been accepted.
    function _acceptFundsFor(
        uint256 projectId,
        address token,
        uint256 amount,
        bytes calldata metadata
    )
        private
        returns (uint256)
    {
        // Make sure the project has an accounting context for the token being paid.
        if (_accountingContextForTokenOf[projectId][token].token == address(0)) {
            revert TOKEN_NOT_ACCEPTED();
        }

        // If the terminal's token is the native token, override `amount` with `msg.value`.
        if (token == JBConstants.NATIVE_TOKEN) return msg.value;

        // If the terminal's token is not native, revert if there is a non-zero `msg.value`.
        if (msg.value != 0) revert NO_MSG_VALUE_ALLOWED();

        // If the terminal is rerouting the tokens within its own functions, there's nothing to transfer.
        if (_msgSender() == address(this)) return amount;

        // The metadata ID is the first 4 bytes of this contract's address.
        bytes4 metadataId = bytes4(bytes20(address(this)));

        // Unpack the allowance to use, if any, given by the frontend.
        (bool exists, bytes memory parsedMetadata) = JBMetadataResolver.getDataFor(metadataId, metadata);

        // Check if the metadata contains permit data.
        if (exists) {
            // Keep a reference to the allowance context parsed from the metadata.
            (JBSingleAllowanceContext memory allowance) = abi.decode(parsedMetadata, (JBSingleAllowanceContext));

            // Make sure the permit allowance is enough for this payment. If not we revert early.
            if (allowance.amount < amount) {
                revert PERMIT_ALLOWANCE_NOT_ENOUGH();
            }

            // Set the allowance to `spend` tokens for the user.
            PERMIT2.permit({
                owner: _msgSender(),
                permitSingle: IAllowanceTransfer.PermitSingle({
                    details: IAllowanceTransfer.PermitDetails({
                        token: token,
                        amount: allowance.amount,
                        expiration: allowance.expiration,
                        nonce: allowance.nonce
                    }),
                    spender: address(this),
                    sigDeadline: allowance.sigDeadline
                }),
                signature: allowance.signature
            });
        }

        // Get a reference to the balance before receiving tokens.
        uint256 balanceBefore = _balance(token);

        // Transfer tokens to this terminal from the msg sender.
        _transferFrom({from: _msgSender(), to: payable(address(this)), token: token, amount: amount});

        // The amount should reflect the change in balance.
        return _balance(token) - balanceBefore;
    }

    /// @notice Pay a project with tokens.
    /// @param projectId The ID of the project being paid.
    /// @param token The address of the token which the project is being paid with.
    /// @param amount The amount of terminal tokens being received, as a fixed point number with the same number of
    /// decimals as this terminal. If this terminal's token is the native token, `amount` is ignored and `msg.value` is
    /// used in its place.
    /// @param payer The address making the payment.
    /// @param beneficiary The address to mint tokens to, and pass along to the ruleset's data hook and pay hook if
    /// applicable.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Bytes to send along to the emitted event, as well as the data hook and pay hook if applicable.
    /// @return beneficiaryTokenCount The number of tokens minted and sent to the beneficiary, as a fixed point number
    /// with 18 decimals.
    function _pay(
        uint256 projectId,
        address token,
        uint256 amount,
        address payer,
        address beneficiary,
        string memory memo,
        bytes memory metadata
    )
        private
        returns (uint256 beneficiaryTokenCount)
    {
        // Keep a reference to the ruleset the payment is being made during.
        JBRuleset memory ruleset;

        // Keep a reference to the pay hook specifications.
        JBPayHookSpecification[] memory hookSpecifications;

        // Keep a reference to the token count that'll be minted as a result of the payment.
        uint256 tokenCount;

        // Keep a reference to the token amount to forward to the store.
        JBTokenAmount memory tokenAmount;

        // Scoped section prevents stack too deep. `context` only used within scope.
        {
            // Get a reference to the token's accounting context.
            JBAccountingContext memory context = _accountingContextForTokenOf[projectId][token];

            // Bundle the amount info into a `JBTokenAmount` struct.
            tokenAmount = JBTokenAmount(token, amount, context.decimals, context.currency);
        }

        // Record the payment.
        (ruleset, tokenCount, hookSpecifications) = STORE.recordPaymentFrom({
            payer: payer,
            amount: tokenAmount,
            projectId: projectId,
            beneficiary: beneficiary,
            metadata: metadata
        });

        // Mint tokens if needed.
        if (tokenCount != 0) {
            // Set the token count to be the number of tokens minted for the beneficiary instead of the total
            // amount.
            beneficiaryTokenCount = IJBController(address(DIRECTORY.controllerOf(projectId))).mintTokensOf({
                projectId: projectId,
                tokenCount: tokenCount,
                beneficiary: beneficiary,
                memo: "",
                useReservedRate: true
            });
        }

        // If the data hook returned pay hook specifications, fulfill them.
        if (hookSpecifications.length != 0) {
            _fulfillPayHookSpecificationsFor(
                projectId, hookSpecifications, tokenAmount, payer, ruleset, beneficiary, beneficiaryTokenCount, metadata
            );
        }

        emit Pay(
            ruleset.id,
            ruleset.cycleNumber,
            projectId,
            payer,
            beneficiary,
            amount,
            beneficiaryTokenCount,
            memo,
            metadata,
            _msgSender()
        );
    }

    /// @notice Adds funds to a project's balance without minting tokens.
    /// @param projectId The ID of the project to add funds to the balance of.
    /// @param token The address of the token being added to the project's balance.
    /// @param amount The amount of tokens to add as a fixed point number with the same number of decimals as this
    /// terminal. If this is a native token terminal, this is ignored and `msg.value` is used instead.
    /// @param shouldReturnHeldFees A flag indicating if held fees should be returned based on the amount being added.
    /// @param memo A memo to pass along to the emitted event.
    /// @param metadata Extra data to pass along to the emitted event.
    function _addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool shouldReturnHeldFees,
        string memory memo,
        bytes memory metadata
    )
        private
    {
        // Return held fees if desired. This mechanism means projects don't pay fees multiple times when funds go out of
        // and back into the protocol.
        uint256 returnedFees = shouldReturnHeldFees ? _returnHeldFees(projectId, token, amount) : 0;

        // Record the added funds with any returned fees.
        STORE.recordAddedBalanceFor({projectId: projectId, token: token, amount: amount + returnedFees});

        emit AddToBalance(projectId, amount, returnedFees, memo, metadata, _msgSender());
    }

    /// @notice Holders can redeem their tokens to claim some of a project's surplus, or to trigger rules determined by
    /// the project's current ruleset's data hook.
    /// @dev Only a token holder or a an operator with the `REDEEM_TOKENS` permission from that holder can redeem those
    /// tokens.
    /// @param holder The account redeeming tokens.
    /// @param projectId The ID of the project whose tokens are being redeemed.
    /// @param tokenToReclaim The address of the token which is being reclaimed.
    /// @param redeemCount The number of project tokens to redeem, as a fixed point number with 18 decimals.
    /// @param beneficiary The address to send the reclaimed terminal tokens to.
    /// @param metadata Bytes to send along to the emitted event, as well as the data hook and redeem hook if
    /// applicable.
    /// @return reclaimAmount The number of terminal tokens reclaimed for the `beneficiary`, as a fixed point number
    /// with 18 decimals.
    function _redeemTokensOf(
        address holder,
        uint256 projectId,
        address tokenToReclaim,
        uint256 redeemCount,
        address payable beneficiary,
        bytes memory metadata
    )
        private
        returns (uint256 reclaimAmount)
    {
        // Keep a reference to the ruleset the redemption is being made during.
        JBRuleset memory ruleset;

        // Keep a reference to the redeem hook specifications.
        JBRedeemHookSpecification[] memory hookSpecifications;

        // Record the redemption.
        (ruleset, reclaimAmount, hookSpecifications) = STORE.recordRedemptionFor({
            holder: holder,
            projectId: projectId,
            accountingContext: _accountingContextForTokenOf[projectId][tokenToReclaim],
            balanceAccountingContexts: _accountingContextsOf[projectId],
            redeemCount: redeemCount,
            metadata: metadata
        });

        // Burn the project tokens.
        if (redeemCount != 0) {
            IJBController(address(DIRECTORY.controllerOf(projectId))).burnTokensOf({
                holder: holder,
                projectId: projectId,
                tokenCount: redeemCount,
                memo: ""
            });
        }

        // Determine if a fee should be taken. Fees are not exercised if the redemption rate is at its max (100%),
        // if the beneficiary is feeless, or if the fee beneficiary doesn't accept the given token.
        bool takesFee =
            !FEELESS_ADDRESSES.isFeeless(beneficiary) && ruleset.redemptionRate() != JBConstants.MAX_REDEMPTION_RATE;

        // Keep a reference to the amount being reclaimed that is subject to fees.
        uint256 amountEligibleForFees;

        // If the data hook returned redeem hook specifications, fulfill them.
        if (hookSpecifications.length != 0) {
            // Get a reference to the token's accounting context.
            JBAccountingContext memory context = _accountingContextForTokenOf[projectId][tokenToReclaim];

            // Fulfill the redeem hook specifications.
            amountEligibleForFees += _fulfillRedeemHookSpecificationsFor({
                projectId: projectId,
                holder: holder,
                redeemCount: redeemCount,
                ruleset: ruleset,
                beneficiary: beneficiary,
                beneficiaryReclaimAmount: JBTokenAmount(tokenToReclaim, reclaimAmount, context.decimals, context.currency),
                specifications: hookSpecifications,
                takesFee: takesFee,
                metadata: metadata
            });
        }

        // Send the reclaimed funds to the beneficiary.
        if (reclaimAmount != 0) {
            if (takesFee) {
                amountEligibleForFees += reclaimAmount;
                // Subtract the fee for the reclaimed amount.
                reclaimAmount -= JBFees.feeAmountIn(reclaimAmount, FEE);
            }

            // Subtract the fee from the reclaim amount.
            if (reclaimAmount != 0) {
                _transferFrom({from: address(this), to: beneficiary, token: tokenToReclaim, amount: reclaimAmount});
            }
        }

        // Take the fee from all outbound reclaimings.
        amountEligibleForFees != 0
            ? _takeFeeFrom({
                projectId: projectId,
                token: tokenToReclaim,
                amount: amountEligibleForFees,
                beneficiary: beneficiary,
                shouldHoldFees: false
            })
            : 0;

        emit RedeemTokens(
            ruleset.id,
            ruleset.cycleNumber,
            projectId,
            holder,
            beneficiary,
            redeemCount,
            reclaimAmount,
            metadata,
            _msgSender()
        );
    }

    /// @notice Sends payouts to a project's current payout split group, according to its ruleset, up to its current
    /// payout limit.
    /// @dev If the percentages of the splits in the project's payout split group do not add up to 100%, the remainder
    /// is sent to the project's owner.
    /// @dev Anyone can send payouts on a project's behalf. Projects can include a wildcard split (a split with no
    /// `hook`, `projectId`, or `beneficiary`) to send funds to the `_msgSender()` which calls this function. This can
    /// be used to incentivize calling this function.
    /// @dev Payouts sent to addresses which aren't feeless incur the protocol fee.
    /// @param projectId The ID of the project to send the payouts of.
    /// @param token The token being paid out.
    /// @param amount The number of terminal tokens to pay out, as a fixed point number with same number of decimals as
    /// this terminal.
    /// @param currency The expected currency of the amount being paid out. Must match the currency of one of the
    /// project's current ruleset's payout limits.
    /// @return amountPaidOut The total amount that was paid out.
    function _sendPayoutsOf(
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 currency
    )
        private
        returns (uint256 amountPaidOut)
    {
        // Keep a reference to the ruleset.
        JBRuleset memory ruleset;

        // Record the payout.
        (ruleset, amountPaidOut) = STORE.recordPayoutFor({
            projectId: projectId,
            accountingContext: _accountingContextForTokenOf[projectId][token],
            amount: amount,
            currency: currency
        });

        // Get a reference to the project's owner.
        // The owner will receive tokens minted by paying the platform fee and receive any leftover funds not sent to
        // payout splits.
        address payable projectOwner = payable(PROJECTS.ownerOf(projectId));

        // Send payouts to the splits and get a reference to the amount left over after the splits have been paid.
        // Also get a reference to the amount which was paid out to splits that is eligible for fees.
        (uint256 leftoverPayoutAmount, uint256 amountEligibleForFees) =
            _sendPayoutsToSplitGroupOf(projectId, token, ruleset.id, amountPaidOut);

        // Take the fee.
        uint256 feeTaken = _takeFeeFrom({
            projectId: projectId,
            token: token,
            amount: amountEligibleForFees + leftoverPayoutAmount,
            beneficiary: projectOwner,
            shouldHoldFees: ruleset.holdFees()
        });

        /// The leftover amount that was sent to the project owner.
        uint256 netLeftoverPayoutAmount;

        // Send any leftover funds to the project owner and update the net leftover (which is returned) accordingly.
        if (leftoverPayoutAmount != 0) {
            // Subtract the fee from the net leftover amount.
            netLeftoverPayoutAmount = leftoverPayoutAmount - JBFees.feeAmountIn(leftoverPayoutAmount, FEE);

            // Transfer the amount to the project owner.
            _transferFrom({from: address(this), to: projectOwner, token: token, amount: netLeftoverPayoutAmount});
        }

        emit SendPayouts(
            ruleset.id,
            ruleset.cycleNumber,
            projectId,
            projectOwner,
            amount,
            amountPaidOut,
            feeTaken,
            netLeftoverPayoutAmount,
            _msgSender()
        );
    }

    /// @notice Allows a project to send out funds from its surplus up to the current surplus allowance.
    /// @dev Only a project's owner or an operator with the `USE_ALLOWANCE` permission from that owner can use the
    /// surplus allowance.
    /// @dev Incurs the protocol fee unless the caller is a feeless address.
    /// @param projectId The ID of the project to use the surplus allowance of.
    /// @param token The token being paid out from the surplus.
    /// @param amount The amount of terminal tokens to use from the project's current surplus allowance, as a fixed
    /// point number with the same amount of decimals as this terminal.
    /// @param currency The expected currency of the amount being paid out. Must match the currency of one of the
    /// project's current ruleset's surplus allowances.
    /// @param beneficiary The address to send the funds to.
    /// @param memo A memo to pass along to the emitted event.
    /// @return amountPaidOut The amount of tokens paid out.
    function _useAllowanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        uint256 currency,
        address payable beneficiary,
        string memory memo
    )
        private
        returns (uint256 amountPaidOut)
    {
        // Keep a reference to the ruleset.
        JBRuleset memory ruleset;

        // Record the use of the allowance.
        (ruleset, amountPaidOut) = STORE.recordUsedAllowanceOf({
            projectId: projectId,
            accountingContext: _accountingContextForTokenOf[projectId][token],
            amount: amount,
            currency: currency
        });

        // Take a fee from the `amountPaidOut`, if needed.
        // The net amount is the final amount withdrawn after the fee has been taken.
        uint256 netAmountPaidOut = amountPaidOut
            - (
                FEELESS_ADDRESSES.isFeeless(_msgSender())
                    ? 0
                    : _takeFeeFrom({
                        projectId: projectId,
                        token: token,
                        amount: amountPaidOut,
                        // The project owner will receive tokens minted by paying the platform fee.
                        beneficiary: PROJECTS.ownerOf(projectId),
                        shouldHoldFees: ruleset.holdFees()
                    })
            );

        // Transfer any remaining balance to the beneficiary.
        if (netAmountPaidOut != 0) {
            _transferFrom({from: address(this), to: beneficiary, token: token, amount: netAmountPaidOut});
        }

        emit UseAllowance(
            ruleset.id,
            ruleset.cycleNumber,
            projectId,
            beneficiary,
            amount,
            amountPaidOut,
            netAmountPaidOut,
            memo,
            _msgSender()
        );
    }

    /// @notice Sends payouts to the payout splits group specified in a project's ruleset.
    /// @param projectId The ID of the project to send the payouts of.
    /// @param token The address of the token being paid out.
    /// @param rulesetId The ID of the ruleset of the split group being paid.
    /// @param amount The total amount being paid out, as a fixed point number with the same number of decimals as this
    /// terminal.
    /// @return amount The leftover amount (zero if the splits add up to 100%).
    /// @return amountEligibleForFees The total amount of funds which were paid out and are eligible for fees.
    function _sendPayoutsToSplitGroupOf(
        uint256 projectId,
        address token,
        uint256 rulesetId,
        uint256 amount
    )
        private
        returns (uint256, uint256 amountEligibleForFees)
    {
        // The total percentage available to split
        uint256 leftoverPercentage = JBConstants.SPLITS_TOTAL_PERCENT;

        // Get a reference to the project's payout splits.
        JBSplit[] memory splits = SPLITS.splitsOf(projectId, rulesetId, uint256(uint160(token)));

        // Keep a reference to the number of splits being iterated on.
        uint256 numberOfSplits = splits.length;

        // Keep a reference to the split being iterated on.
        JBSplit memory split;

        // Transfer between all splits.
        for (uint256 i; i < numberOfSplits; i++) {
            // Get a reference to the split being iterated on.
            split = splits[i];

            // The amount to send to the split.
            uint256 payoutAmount = mulDiv(amount, split.percent, leftoverPercentage);

            // The final payout amount after taking out any fees.
            uint256 netPayoutAmount = _sendPayoutToSplit(split, projectId, token, payoutAmount);

            // If the split hook is a feeless address, this payout doesn't incur a fee.
            if (netPayoutAmount != 0 && netPayoutAmount != payoutAmount) {
                amountEligibleForFees += payoutAmount;
            }

            if (payoutAmount != 0) {
                // Subtract from the amount to be sent to the beneficiary.
                unchecked {
                    amount -= payoutAmount;
                }
            }

            unchecked {
                // Decrement the leftover percentage.
                leftoverPercentage -= split.percent;
            }

            emit SendPayoutToSplit(
                projectId, rulesetId, uint256(uint160(token)), split, payoutAmount, netPayoutAmount, _msgSender()
            );
        }

        return (amount, amountEligibleForFees);
    }

    /// @notice Sends a payout to a split.
    /// @param split The split to pay.
    /// @param projectId The ID of the project the split was specified by.
    /// @param token The address of the token being paid out.
    /// @param amount The total amount that the split is being paid, as a fixed point number with the same number of
    /// decimals as this terminal.
    /// @return netPayoutAmount The amount sent to the split after subtracting fees.
    function _sendPayoutToSplit(
        JBSplit memory split,
        uint256 projectId,
        address token,
        uint256 amount
    )
        private
        returns (uint256)
    {
        // Attempt to distribute this split.
        try this.executePayout(split, projectId, token, amount, _msgSender()) returns (uint256 netPayoutAmount) {
            return netPayoutAmount;
        } catch (bytes memory failureReason) {
            // Add balance back to the project.
            STORE.recordAddedBalanceFor(projectId, token, amount);
            // Emit event.
            emit PayoutReverted(projectId, split, amount, failureReason, _msgSender());
            // Since the payout failed the netPayoutAmount is zero.
            return 0;
        }
    }

    /// @notice Fulfills a list of pay hook specifications.
    /// @param projectId The ID of the project being paid.
    /// @param specifications The pay hook specifications to be fulfilled.
    /// @param tokenAmount The amount of tokens that the project was paid.
    /// @param payer The address that sent the payment.
    /// @param ruleset The ruleset the payment is being accepted during.
    /// @param beneficiary The address which will receive any tokens that the payment yields.
    /// @param beneficiaryTokenCount The amount of tokens that are being minted and sent to the beneificary.
    /// @param metadata Bytes to send along to the emitted event and pay hooks as applicable.
    function _fulfillPayHookSpecificationsFor(
        uint256 projectId,
        JBPayHookSpecification[] memory specifications,
        JBTokenAmount memory tokenAmount,
        address payer,
        JBRuleset memory ruleset,
        address beneficiary,
        uint256 beneficiaryTokenCount,
        bytes memory metadata
    )
        private
    {
        // Keep a reference to payment context for the pay hooks.
        JBAfterPayRecordedContext memory context = JBAfterPayRecordedContext({
            payer: payer,
            projectId: projectId,
            rulesetId: ruleset.id,
            amount: tokenAmount,
            forwardedAmount: tokenAmount,
            weight: ruleset.weight,
            projectTokenCount: beneficiaryTokenCount,
            beneficiary: beneficiary,
            hookMetadata: bytes(""),
            payerMetadata: metadata
        });

        // Keep a reference to the number of pay hook specifications to iterate through.
        uint256 numberOfSpecifications = specifications.length;

        // Keep a reference to the specification being iterated on.
        JBPayHookSpecification memory specification;

        // Fulfill each specification through their pay hooks.
        for (uint256 i; i < numberOfSpecifications; i++) {
            // Set the specification being iterated on.
            specification = specifications[i];

            // Pass the correct token `forwardedAmount` to the hook.
            context.forwardedAmount = JBTokenAmount({
                value: specification.amount,
                token: tokenAmount.token,
                decimals: tokenAmount.decimals,
                currency: tokenAmount.currency
            });

            // Pass the correct metadata from the data hook's specification.
            context.hookMetadata = specification.metadata;

            // Trigger any inherited pre-transfer logic.
            _beforeTransferTo({to: address(specification.hook), token: tokenAmount.token, amount: specification.amount});

            // Keep a reference to the amount that'll be paid as a `msg.value`.
            uint256 payValue = tokenAmount.token == JBConstants.NATIVE_TOKEN ? specification.amount : 0;

            // Fulfill the specification.
            specification.hook.afterPayRecordedWith{value: payValue}(context);

            emit HookAfterRecordPay(specification.hook, context, specification.amount, _msgSender());
        }
    }

    /// @notice Fulfills a list of redeem hook specification.
    /// @param projectId The ID of the project being redeemed from.
    /// @param beneficiaryReclaimAmount The number of tokens that are being reclaimed from the project.
    /// @param holder The address that holds the tokens being redeemed.
    /// @param redeemCount The number of tokens being redeemed.
    /// @param metadata Bytes to send along to the emitted event and redeem hooks as applicable.
    /// @param ruleset The ruleset the redemption is being made during as a `JBRuleset` struct.
    /// @param beneficiary The address which will receive any terminal tokens that are reclaimed by this redemption.
    /// @param specifications The hook specifications being fulfilled.
    /// @param takesFee A flag indicating if a fee should be taken from the amount sent to hooks.
    /// @return amountEligibleForFees The amount of funds which were allocated to redeem hooks and are eligible for
    /// fees.
    function _fulfillRedeemHookSpecificationsFor(
        uint256 projectId,
        JBTokenAmount memory beneficiaryReclaimAmount,
        address holder,
        uint256 redeemCount,
        bytes memory metadata,
        JBRuleset memory ruleset,
        address payable beneficiary,
        JBRedeemHookSpecification[] memory specifications,
        bool takesFee
    )
        private
        returns (uint256 amountEligibleForFees)
    {
        // Keep a reference to redemption context for the redeem hooks.
        JBAfterRedeemRecordedContext memory context = JBAfterRedeemRecordedContext({
            holder: holder,
            projectId: projectId,
            rulesetId: ruleset.id,
            redeemCount: redeemCount,
            reclaimedAmount: beneficiaryReclaimAmount,
            forwardedAmount: beneficiaryReclaimAmount,
            redemptionRate: ruleset.redemptionRate(),
            beneficiary: beneficiary,
            hookMetadata: "",
            redeemerMetadata: metadata
        });

        // Keep a reference to the number of redeem hook specifications being iterated through.
        uint256 numberOfSpecifications = specifications.length;

        // Keep a reference to the specification being iterated on.
        JBRedeemHookSpecification memory specification;

        for (uint256 i; i < numberOfSpecifications; i++) {
            // Set the specification being iterated on.
            specification = specifications[i];

            // Trigger any inherited pre-transfer logic.
            _beforeTransferTo({
                to: address(specification.hook),
                token: beneficiaryReclaimAmount.token,
                amount: specification.amount
            });

            // Get the fee for the specified amount.
            uint256 specificationAmountFee = takesFee ? JBFees.feeAmountIn(specification.amount, FEE) : 0;

            // Add the specification's amount to the amount eligible for fees.
            if (specificationAmountFee != 0) {
                amountEligibleForFees += specification.amount;
                specification.amount -= specificationAmountFee;
            }

            // Pass the correct token `forwardedAmount` to the hook.
            context.forwardedAmount = JBTokenAmount({
                value: specification.amount,
                token: beneficiaryReclaimAmount.token,
                decimals: beneficiaryReclaimAmount.decimals,
                currency: beneficiaryReclaimAmount.currency
            });

            // Pass the correct metadata from the data hook's specification.
            context.hookMetadata = specification.metadata;

            // Keep a reference to the amount that'll be paid as a `msg.value`.
            uint256 payValue = beneficiaryReclaimAmount.token == JBConstants.NATIVE_TOKEN ? specification.amount : 0;

            // Fulfill the specification.
            specification.hook.afterRedeemRecordedWith{value: payValue}(context);

            emit HookAfterRecordRedeem(
                specification.hook, context, specification.amount, specificationAmountFee, _msgSender()
            );
        }
    }

    /// @notice Takes a fee into the platform's project (with the `_FEE_BENEFICIARY_PROJECT_ID`).
    /// @param projectId The ID of the project paying the fee.
    /// @param token The address of the token that the fee is being paid in.
    /// @param amount The fee's token amount, as a fixed point number with 18 decimals.
    /// @param beneficiary The address to mint the platform's project's tokens for.
    /// @param shouldHoldFees If fees should be tracked and held instead of being exercised immediately.
    /// @return feeAmount The amount of the fee taken.
    function _takeFeeFrom(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        bool shouldHoldFees
    )
        private
        returns (uint256 feeAmount)
    {
        // Get a reference to the fee amount.
        feeAmount = JBFees.feeAmountIn(amount, FEE);

        if (shouldHoldFees) {
            // Store the held fee.
            _heldFeesOf[projectId][token].push(
                JBFee({
                    amount: amount,
                    beneficiary: beneficiary,
                    unlockTimestamp: block.timestamp + _FEE_HOLDING_SECONDS
                })
            );

            emit HoldFee(projectId, token, amount, FEE, beneficiary, _msgSender());
        } else {
            // Get the terminal that'll receive the fee if one wasn't provided.
            IJBTerminal feeTerminal = DIRECTORY.primaryTerminalOf(_FEE_BENEFICIARY_PROJECT_ID, token);

            // Process the fee.
            _processFee({
                projectId: projectId,
                token: token,
                amount: feeAmount,
                beneficiary: beneficiary,
                feeTerminal: feeTerminal,
                wasHeld: false
            });
        }
    }

    /// @notice Process any fees that are being held for the project.
    /// @param projectId The ID of the project to process held fees for.
    /// @param token The token to process held fees for.
    /// @param forced If locked held fees should be force processed.
    function _processHeldFeesOf(uint256 projectId, address token, bool forced) private {
        // Get a reference to the project's held fees.
        JBFee[] memory heldFees = _heldFeesOf[projectId][token];

        // Delete the held fees.
        delete _heldFeesOf[projectId][token];

        // Keep a reference to the number of held fees.
        uint256 numberOfHeldFees = heldFees.length;

        // Keep a reference to the fee being iterated on.
        JBFee memory heldFee;

        // Keep a reference to the terminal that'll receive the fees.
        IJBTerminal feeTerminal = DIRECTORY.primaryTerminalOf(_FEE_BENEFICIARY_PROJECT_ID, token);

        // Process each fee.
        for (uint256 i; i < numberOfHeldFees; i++) {
            // Keep a reference to the held fee being iterated on.
            heldFee = heldFees[i];

            // Can't process fees that aren't yet unlocked.
            if (!forced && heldFee.unlockTimestamp > block.timestamp) {
                // Add the fee back to storage.
                _heldFeesOf[projectId][token].push(heldFee);
                continue;
            }

            // Process the fee.
            _processFee({
                projectId: projectId,
                token: token,
                amount: heldFee.amount,
                beneficiary: heldFee.beneficiary,
                feeTerminal: feeTerminal,
                wasHeld: true
            });
        }
    }

    /// @notice Process a fee of the specified amount from a project.
    /// @param projectId The ID of the project paying the fee.
    /// @param token The token the fee is being paid in.
    /// @param amount The fee amount, as a fixed point number with 18 decimals.
    /// @param beneficiary The address which will receive any platform tokens minted.
    /// @param feeTerminal The terminal that'll receive the fee.
    /// @param wasHeld A flag indicating if the fee being processed was being held by this terminal.
    function _processFee(
        uint256 projectId,
        address token,
        uint256 amount,
        address beneficiary,
        IJBTerminal feeTerminal,
        bool wasHeld
    )
        private
    {
        try this.executeProcessFee(projectId, token, amount, beneficiary, feeTerminal) {
            emit ProcessFee(projectId, token, amount, wasHeld, beneficiary, _msgSender());
        } catch (bytes memory reason) {
            STORE.recordAddedBalanceFor(projectId, token, amount);

            emit FeeReverted(projectId, token, _FEE_BENEFICIARY_PROJECT_ID, amount, reason, _msgSender());
        }
    }

    /// @notice Returns held fees to the project who paid them based on the specified amount.
    /// @param projectId The project held fees are being returned to.
    /// @param token The token that the held fees are in.
    /// @param amount The amount to base the calculation on, as a fixed point number with the same number of decimals
    /// as this terminal.
    /// @return returnedFees The amount of held fees that were returned, as a fixed point number with the same number of
    /// decimals as this terminal
    function _returnHeldFees(uint256 projectId, address token, uint256 amount) private returns (uint256 returnedFees) {
        // Get a reference to the project's held fees.
        JBFee[] memory heldFees = _heldFeesOf[projectId][token];

        // Delete the current held fees.
        delete _heldFeesOf[projectId][token];

        // Get a reference to the leftover amount once all fees have been settled.
        uint256 leftoverAmount = amount;

        // Keep a reference to the number of held fees.
        uint256 numberOfHeldFees = heldFees.length;

        // Keep a reference to the fee being iterated on.
        JBFee memory heldFee;

        // Process each fee.
        for (uint256 i; i < numberOfHeldFees; i++) {
            // Save the fee being iterated on.
            heldFee = heldFees[i];

            if (leftoverAmount == 0) {
                _heldFeesOf[projectId][token].push(heldFee);
            } else {
                // Notice here we take `feeAmountIn` on the stored `.amount`.
                uint256 feeAmount = JBFees.feeAmountIn(heldFee.amount, FEE);

                // Keep a reference to the amount from which the fee was taken.
                uint256 amountFromFee = heldFee.amount - feeAmount;

                if (leftoverAmount >= amountFromFee) {
                    unchecked {
                        leftoverAmount = leftoverAmount - amountFromFee;
                        returnedFees += feeAmount;
                    }
                } else {
                    // And here we overwrite with `feeAmountFrom` the `leftoverAmount`
                    feeAmount = JBFees.feeAmountFrom(leftoverAmount, FEE);

                    unchecked {
                        _heldFeesOf[projectId][token].push(
                            JBFee({
                                amount: amountFromFee - leftoverAmount,
                                beneficiary: heldFee.beneficiary,
                                unlockTimestamp: heldFee.unlockTimestamp
                            })
                        );
                        returnedFees += feeAmount;
                    }
                    leftoverAmount = 0;
                }
            }
        }

        emit ReturnHeldFees(projectId, token, amount, returnedFees, leftoverAmount, _msgSender());
    }

    /// @notice Transfers tokens.
    /// @param from The address the transfer should originate from.
    /// @param to The address the transfer should go to.
    /// @param token The token being transfered.
    /// @param amount The number of tokens being transferred, as a fixed point number with the same number of decimals
    /// as this terminal.
    function _transferFrom(address from, address payable to, address token, uint256 amount) private {
        // If the token is the native token, transfer natively.
        if (token == JBConstants.NATIVE_TOKEN) return Address.sendValue(to, amount);

        if (from == address(this)) return IERC20(token).safeTransfer(to, amount);

        // If there's sufficient approval, transfer normally.
        if (IERC20(token).allowance(address(from), address(this)) >= amount) {
            return IERC20(token).safeTransferFrom(from, to, amount);
        }

        // Make sure the amount being paid is less than the maximum permit2 allowance.
        if (amount > type(uint160).max) revert OVERFLOW_ALERT();

        // Otherwise we attempt to use the PERMIT2 method.
        PERMIT2.transferFrom(from, to, uint160(amount), token);
    }

    /// @notice Logic to be triggered before transferring tokens from this terminal.
    /// @param to The address the transfer is going to.
    /// @param token The token being transferred.
    /// @param amount The number of tokens being transferred, as a fixed point number with the same number of decimals
    /// as this terminal.
    function _beforeTransferTo(address to, address token, uint256 amount) private {
        // If the token is the native token, no allowance needed.
        if (token == JBConstants.NATIVE_TOKEN) return;
        IERC20(token).safeIncreaseAllowance(to, amount);
    }
}
