// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";

contract TestMintTokensOf_Local is TestBaseWorkflow {
    uint8 private constant _WEIGHT_DECIMALS = 18;
    uint256 private constant _WEIGHT = 1000 * 10 ** _WEIGHT_DECIMALS;
    address private constant _DATA_HOOK = address(bytes20(keccak256("datahook")));

    IJBController private _controller;
    IJBTerminal private _terminal;
    IJBTokens private _tokens;
    address private _projectOwner;

    uint256 _projectId;

    function setUp() public override {
        super.setUp();

        _controller = jbController();
        _projectOwner = multisig();
        _terminal = jbMultiTerminal();
        _tokens = jbTokens();

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedRate: 0,
            redemptionRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowControllerMigration: false,
            allowSetController: false,
            holdFees: false,
            useTotalSurplusForRedemptions: false,
            useDataHookForPay: true,
            useDataHookForRedeem: true,
            dataHook: _DATA_HOOK,
            metadata: 0
        });

        // Package up ruleset configuration.
        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].duration = 0;
        _rulesetConfig[0].weight = _WEIGHT;
        _rulesetConfig[0].decayRate = 0;
        _rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
        address[] memory _tokensToAccept = new address[](1);
        _tokensToAccept[0] = JBConstants.NATIVE_TOKEN;
        _terminalConfigurations[0] = JBTerminalConfig({terminal: _terminal, tokensToAccept: _tokensToAccept});

        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectMetadata: "myIPFSHash",
            rulesetConfigurations: _rulesetConfig,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });
    }

    function test_GivenNoRulesetIsActive() external {
        // deploy a second project without ruleset
        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedRate: 0,
            redemptionRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: true,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowControllerMigration: false,
            allowSetController: false,
            holdFees: false,
            useTotalSurplusForRedemptions: false,
            useDataHookForPay: true,
            useDataHookForRedeem: true,
            dataHook: _DATA_HOOK,
            metadata: 0
        });

        // Package up ruleset configuration that starts in the future.
        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = block.timestamp + 100;
        _rulesetConfig[0].duration = 0;
        _rulesetConfig[0].weight = _WEIGHT;
        _rulesetConfig[0].decayRate = 0;
        _rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
        address[] memory _tokensToAccept = new address[](1);
        _tokensToAccept[0] = JBConstants.NATIVE_TOKEN;
        _terminalConfigurations[0] = JBTerminalConfig({terminal: _terminal, tokensToAccept: _tokensToAccept});

        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectMetadata: "myIPFSHash",
            rulesetConfigurations: _rulesetConfig,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });

        // owner should be able to mint
        vm.prank(_projectOwner);

        // send: mint some tokens
        _controller.mintTokensOf(2, 1, address(this), "", false);

        // check: tokens were minted
        uint256 balance = _tokens.totalBalanceOf(address(this), 2);
        assertEq(balance, 1);
    }

    function test_GivenThatADataSourceIsConfigured() external {
        // it should be able to mint
        vm.prank(address(_DATA_HOOK));

        // send: mint some tokens
        _controller.mintTokensOf(1, 1, address(this), "", false);

        // check: tokens were minted
        uint256 balance = _tokens.totalBalanceOf(address(this), 1);
        assertEq(balance, 1);
    }

    function test_GivenThatADataSourceHasPermissionedAnotherContractToMint() external {
        // it should be able to mint

        // setup: mock the datasource mint permission, allowing this contract to mint
        bytes memory _encodedCall = abi.encodeCall(IJBRulesetDataHook.hasMintPermissionFor, (1, address(this)));
        bytes memory _willReturn = abi.encode(true);

        vm.mockCall(address(_DATA_HOOK), _encodedCall, _willReturn);
        vm.expectCall(address(_DATA_HOOK), _encodedCall);

        // send: mint some tokens
        _controller.mintTokensOf(1, 1, address(this), "", false);

        // check: tokens were minted
        uint256 balance = _tokens.totalBalanceOf(address(this), 1);
        assertEq(balance, 1);
    }
}
