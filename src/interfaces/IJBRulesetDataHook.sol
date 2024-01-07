// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {JBPayHookSpecification} from "./../structs/JBPayHookSpecification.sol";
import {JBBeforePayRecordedContext} from "./../structs/JBBeforePayRecordedContext.sol";
import {JBBeforeRedeemRecordedContext} from "./../structs/JBBeforeRedeemRecordedContext.sol";
import {JBRedeemHookSpecification} from "./../structs/JBRedeemHookSpecification.sol";

/// @notice Data hooks can extend a terminal's core pay/redeem functionality by overriding the weight or memo. They can
/// also specify pay/redeem hooks for the terminal to fulfill, or allow addresses to mint a project's tokens on-demand.
/// @dev If a project's ruleset has `useDataHookForPay` or `useDataHookForRedeem` enabled, its `dataHook` is called by
/// the terminal upon payments/redemptions (respectively).
interface IJBRulesetDataHook is IERC165 {
    /// @notice A flag indicating whether an address has permission to mint a project's tokens on-demand.
    /// @dev A project's data hook can allow any address to mint its tokens.
    /// @param projectId The ID of the project whose token can be minted.
    /// @param addr The address to check the token minting permission of.
    /// @return flag A flag indicating whether the address has permission to mint the project's tokens on-demand.
    function hasMintPermissionFor(uint256 projectId, address addr) external view returns (bool flag);

    /// @notice The data calculated before a payment is recorded in the terminal store. This data is provided to the
    /// terminal's `pay(...)` transaction.
    /// @param context The context passed to this data hook by the `pay(...)` function as a `JBBeforePayRecordedContext`
    /// struct.
    /// @return weight The new `weight` to use, overriding the ruleset's `weight`.
    /// @return hookSpecifications The amount and data to send to pay hooks instead of adding to the terminal's balance.
    function beforePayRecordedWith(JBBeforePayRecordedContext calldata context)
        external
        view
        returns (uint256 weight, JBPayHookSpecification[] memory hookSpecifications);

    /// @notice The data calculated before a redemption is recorded in the terminal store. This data is provided to the
    /// terminal's `redeemTokensOf(...)` transaction.
    /// @param context The context passed to this data hook by the `redeemTokensOf(...)` function as a
    /// `JBBeforeRedeemRecordedContext` struct.
    /// @return reclaimAmount The amount to claim, overriding the terminal logic.
    /// @return hookSpecifications The amount and data to send to redeem hooks instead of returning to the beneficiary.
    function beforeRedeemRecordedWith(JBBeforeRedeemRecordedContext calldata context)
        external
        view
        returns (uint256 reclaimAmount, JBRedeemHookSpecification[] memory hookSpecifications);
}
