// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBRuleset} from "./JBRuleset.sol";
import {JBRulesetMetadata} from "./JBRulesetMetadata.sol";

/// @custom:member ruleset The ruleset.
/// @custom:member metadata The ruleset's metadata.
struct JBRulesetWithMetadata {
    JBRuleset ruleset;
    JBRulesetMetadata metadata;
}
