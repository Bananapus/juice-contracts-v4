// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJBPaymentTerminal} from "./../interfaces/IJBPaymentTerminal.sol";
import {JBTokenAmount} from "./JBTokenAmount.sol";

/// @custom:member terminal The terminal that is facilitating the redemption.
/// @custom:member holder The holder of the tokens being redeemed.
/// @custom:member projectId The ID of the project whos tokens are being redeemed.
/// @custom:member currentRulesetId The rulesetId of the ruleset during which the redemption is being made.
/// @custom:member tokenCount The proposed number of tokens being redeemed, as a fixed point number with 18 decimals.
/// @custom:member totalSupply The total supply of tokens used in the calculation, as a fixed point number with 18 decimals.
/// @custom:member surplus The surplus amount used in the reclaim amount calculation.
/// @custom:member reclaimAmount The amount that should be reclaimed by the redeemer using the protocol's standard bonding curve redemption formula. Includes the token being reclaimed, the reclaim value, the number of decimals included, and the currency of the reclaim amount.
/// @custom:member useTotalSurplus If surplus across all of a project's terminals is being used when making redemptions.
/// @custom:member redemptionRate The redemption rate of the ruleset during which the redemption is being made.
/// @custom:member metadata Extra data provided by the redeemer.
struct JBRedeemParamsData {
    IJBPaymentTerminal terminal;
    address holder;
    uint256 projectId;
    uint256 currentRulesetId;
    uint256 tokenCount;
    uint256 totalSupply;
    uint256 surplus;
    JBTokenAmount reclaimAmount;
    bool useTotalSurplus;
    uint256 redemptionRate;
    bytes metadata;
}
