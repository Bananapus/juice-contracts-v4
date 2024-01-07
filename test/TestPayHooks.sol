// SPDX-License-Identifier: MIT
pragma solidity >=0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";

contract TestPayHooks_Local is TestBaseWorkflow {
    uint8 private constant _WEIGHT_DECIMALS = 18;
    uint8 private constant _NATIVE_TOKEN_DECIMALS = 18;
    uint256 private constant _WEIGHT = 1000 * 10 ** _WEIGHT_DECIMALS;
    uint256 private constant _DATA_HOOK_WEIGHT = 2000 * 10 ** _WEIGHT_DECIMALS;
    address private constant _DATA_HOOK = address(bytes20(keccak256("datahook")));
    bytes private constant _PAYER_METADATA = bytes("Some payer metadata");

    IJBController private _controller;
    IJBTerminal private _terminal;
    address private _projectOwner;
    address private _beneficiary;
    address private _payer;

    uint256 _projectId;

    function setUp() public override {
        super.setUp();

        _controller = jbController();
        _projectOwner = multisig();
        _beneficiary = beneficiary();
        _payer = address(1_234_567);
        _terminal = jbMultiTerminal();

        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
            reservedRate: 0,
            redemptionRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
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

    function testPayHooks(uint256 _numberOfSpecifications, uint256 _nativePayAmount) public {
        // Bound the number of specifications to a reasonable amount.
        _numberOfSpecifications = bound(_numberOfSpecifications, 1, 20);
        // Make sure the amount of tokens generated fits in a register, and that each specification can get some.
        _nativePayAmount = bound(_nativePayAmount, _numberOfSpecifications, type(uint256).max / _DATA_HOOK_WEIGHT);

        // epa * weight / epad < max*epad/weight

        // Keep a reference to the specifications.
        JBPayHookSpecification[] memory _specifications = new JBPayHookSpecification[](_numberOfSpecifications);

        // Keep a reference to the amounts in the specifications.
        uint256[] memory _payHookAmounts = new uint256[](_numberOfSpecifications);

        // Keep a reference to the amount that'll be paid and sent to pay hooks.
        uint256 _totalToAllocate = _nativePayAmount;

        // Spread the paid amount through all specifications, in various chunks, omitting the last entry.
        for (uint256 i; i < _numberOfSpecifications - 1; i++) {
            _payHookAmounts[i] = _totalToAllocate / (_payHookAmounts.length * 2);
            _totalToAllocate -= _payHookAmounts[i];
        }

        // Send the rest to the last entry.
        _payHookAmounts[_payHookAmounts.length - 1] = _totalToAllocate;

        // Keep a reference to the current ruleset.
        (JBRuleset memory _ruleset,) = _controller.currentRulesetOf(_projectId);

        // Iterate through each specification.
        for (uint256 i = 0; i < _numberOfSpecifications; i++) {
            // Make up an address for the hook.
            address _hookAddress = address(bytes20(keccak256(abi.encodePacked("PayHook", i))));

            // Send along some metadata to the pay hook.
            bytes memory _hookMetadata = bytes("Some data hook metadata");

            // Package up the specification struct.
            _specifications[i] = JBPayHookSpecification(IJBPayHook(_hookAddress), _payHookAmounts[i], _hookMetadata);

            // Keep a reference to the data that'll be received by the hook.
            JBAfterPayRecordedContext memory _postRecordPayContext = JBAfterPayRecordedContext({
                payer: _payer,
                projectId: _projectId,
                rulesetId: _ruleset.id,
                amount: JBTokenAmount(
                    JBConstants.NATIVE_TOKEN,
                    _nativePayAmount,
                    _terminal.accountingContextForTokenOf(_projectId, JBConstants.NATIVE_TOKEN).decimals,
                    _terminal.accountingContextForTokenOf(_projectId, JBConstants.NATIVE_TOKEN).currency
                    ),
                forwardedAmount: JBTokenAmount(
                    JBConstants.NATIVE_TOKEN,
                    _payHookAmounts[i],
                    _terminal.accountingContextForTokenOf(_projectId, JBConstants.NATIVE_TOKEN).decimals,
                    _terminal.accountingContextForTokenOf(_projectId, JBConstants.NATIVE_TOKEN).currency
                    ),
                weight: _WEIGHT,
                projectTokenCount: mulDiv(_nativePayAmount, _DATA_HOOK_WEIGHT, 10 ** _NATIVE_TOKEN_DECIMALS),
                beneficiary: _beneficiary,
                hookMetadata: _hookMetadata,
                payerMetadata: _PAYER_METADATA
            });

            // Mock the hook.
            vm.mockCall(
                _hookAddress,
                abi.encodeWithSelector(IJBPayHook.afterPayRecordedWith.selector),
                abi.encode(_postRecordPayContext)
            );

            // Assert that the hook gets called with the expected value.
            vm.expectCall(
                _hookAddress,
                _payHookAmounts[i],
                abi.encodeWithSelector(IJBPayHook.afterPayRecordedWith.selector, _postRecordPayContext)
            );

            // Expect an event to be emitted for every hook.
            vm.expectEmit(true, true, true, true);
            emit HookAfterRecordPay(IJBPayHook(_hookAddress), _postRecordPayContext, _payHookAmounts[i], _payer);
        }

        vm.mockCall(
            _DATA_HOOK,
            abi.encodeWithSelector(IJBRulesetDataHook.beforePayRecordedWith.selector),
            abi.encode(_DATA_HOOK_WEIGHT, _specifications)
        );

        vm.deal(_payer, _nativePayAmount);
        vm.prank(_payer);

        // Pay the project such that the `_beneficiary` receives project tokens.
        _terminal.pay{value: _nativePayAmount}({
            projectId: _projectId,
            amount: _nativePayAmount,
            token: JBConstants.NATIVE_TOKEN,
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "Forge Test",
            metadata: _PAYER_METADATA
        });
    }

    event HookAfterRecordPay(
        IJBPayHook indexed hook, JBAfterPayRecordedContext context, uint256 specificationAmount, address caller
    );
}
