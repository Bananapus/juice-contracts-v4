// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBAccountingContext} from "../../structs/JBAccountingContext.sol";
import {JBAfterPayRecordedContext} from "../../structs/JBAfterPayRecordedContext.sol";

import {IJBPayHook} from "../../interfaces/IJBPayHook.sol";
import {IERC165} from "lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";

/// @notice A terminal that accepts payments and can be migrated.
interface IJBTerminal is IERC165 {
    event MigrateTerminal(
        uint256 indexed projectId, address indexed token, IJBTerminal indexed to, uint256 amount, address caller
    );

    event AddToBalance(
        uint256 indexed projectId, uint256 amount, uint256 unlockedFees, string memo, bytes metadata, address caller
    );

    event SetAccountingContext(
        uint256 indexed projectId, address indexed token, JBAccountingContext context, address caller
    );

    event Pay(
        uint256 indexed rulesetId,
        uint256 indexed rulesetCycleNumber,
        uint256 indexed projectId,
        address payer,
        address beneficiary,
        uint256 amount,
        uint256 beneficiaryTokenCount,
        string memo,
        bytes metadata,
        address caller
    );

    event HookAfterRecordPay(
        IJBPayHook indexed hook, JBAfterPayRecordedContext context, uint256 specificationAmount, address caller
    );

    function accountingContextForTokenOf(
        uint256 projectId,
        address token
    )
        external
        view
        returns (JBAccountingContext memory);

    function accountingContextsOf(uint256 projectId) external view returns (JBAccountingContext[] memory);

    function currentSurplusOf(uint256 projectId, uint256 decimals, uint256 currency) external view returns (uint256);

    function migrateBalanceOf(uint256 projectId, address token, IJBTerminal to) external returns (uint256 balance);

    function addAccountingContextsFor(uint256 projectId, address[] calldata tokens) external;

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
        returns (uint256 beneficiaryTokenCount);

    function addToBalanceOf(
        uint256 projectId,
        address token,
        uint256 amount,
        bool shouldReturnHeldFees,
        string calldata memo,
        bytes calldata metadata
    )
        external
        payable;
}
