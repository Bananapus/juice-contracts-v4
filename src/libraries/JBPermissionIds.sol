// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library JBPermissionIds {
    uint256 public constant ROOT = 1;
    uint256 public constant QUEUE_RULESETS = 2;
    uint256 public constant REDEEM_TOKENS = 3;
    uint256 public constant MIGRATE_CONTROLLER = 4;
    uint256 public constant MIGRATE_TERMINAL = 5;
    uint256 public constant PROCESS_FEES = 6;
    uint256 public constant SET_PROJECT_METADATA = 7;
    uint256 public constant ISSUE_TOKEN = 8;
    uint256 public constant SET_TOKEN = 9;
    uint256 public constant MINT_TOKENS = 10;
    uint256 public constant BURN_TOKENS = 11;
    uint256 public constant CLAIM_TOKENS = 12;
    uint256 public constant TRANSFER_TOKENS = 13;
    uint256 public constant SET_CONTROLLER = 14;
    uint256 public constant SET_TERMINALS = 15;
    uint256 public constant SET_PRIMARY_TERMINAL = 16;
    uint256 public constant USE_ALLOWANCE = 17;
    uint256 public constant SET_SPLITS = 18;
    uint256 public constant ADD_PRICE_FEED = 19;
    uint256 public constant SET_ACCOUNTING_CONTEXT = 20;
    // -- NEW PERMISSIONS --
    uint256 public constant MODIFY_DEFAULT_POOL = 21;
    uint256 public constant MODIFY_TWAP_PARAMS = 22;
}
