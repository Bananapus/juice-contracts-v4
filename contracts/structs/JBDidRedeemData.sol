// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBTokenAmount} from './JBTokenAmount.sol';

/// @custom:member holder The holder of the tokens being redeemed.
/// @custom:member projectId The ID of the project with which the redeemed tokens are associated.
/// @custom:member currentRulesetConfiguration The rulesetId of the funding cycle during which the redemption is being made.
/// @custom:member projectTokenCount The number of project tokens being redeemed.
/// @custom:member reclaimedAmount The amount reclaimed from the treasury. Includes the token being reclaimed, the value, the number of decimals included, and the currency of the amount.
/// @custom:member forwardedAmount The amount of the payment that is being sent to the delegate. Includes the token being paid, the value, the number of decimals included, and the currency of the amount.
/// @custom:member beneficiary The address to which the reclaimed amount will be sent.
/// @custom:member metadata Extra data to send to the delegate.
struct JBDidRedeemData {
  address holder;
  uint256 projectId;
  uint256 currentRulesetConfiguration;
  uint256 projectTokenCount;
  JBTokenAmount reclaimedAmount;
  JBTokenAmount forwardedAmount;
  address payable beneficiary;
  bytes metadata;
}
