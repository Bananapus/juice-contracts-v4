// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBTerminal} from "./IJBTerminal.sol";
import {IJBRedeemHook} from "../IJBRedeemHook.sol";
import {JBAfterRedeemRecordedContext} from "../../structs/JBAfterRedeemRecordedContext.sol";

/// @notice A terminal that can be redeemed from.
interface IJBRedeemTerminal is IJBTerminal {
    event RedeemTokens(
        uint256 indexed rulesetId,
        uint256 indexed rulesetCycleNumber,
        uint256 indexed projectId,
        address holder,
        address beneficiary,
        uint256 tokenCount,
        uint256 reclaimedAmount,
        bytes metadata,
        address caller
    );

    event HookAfterRecordRedeem(
        IJBRedeemHook indexed hook,
        JBAfterRedeemRecordedContext context,
        uint256 specificationAmount,
        uint256 fee,
        address caller
    );

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
        returns (uint256 reclaimAmount);
}
