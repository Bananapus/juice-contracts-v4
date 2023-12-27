// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";

/// @notice Swap terminal test on a mainnet fork
contract TestSwapTerminal_Fork is TestBaseWorkflow {
    JBSwapTerminal internal _swapTerminal;
    JBTokens internal _tokens;

    uint256 internal _projectId;
    address internal _projectOwner;
    address internal _terminalOwner;
    address internal _beneficiary;

    address DAI = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IWETH9 WETH = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setUp() public {
        vm.createSelectFork("https://rpc.ankr.com/eth",18819734);

        _projects;

        _permissions;

        _directory;

        _permit2;

        _tokens;

        _terminalStore;

        _swapTerminal = new JBSwapTerminal(
            IJBProjects _projects,
            IJBPermissions _permissions,
            IJBDirectory _directory,
            IPermit2 _permit2,
            address _owner,
            IWETH9 _weth
        );
    }
    
    /// @notice Test paying a swap terminal in DAI to contribute to JuiceboxDAO project (in the eth terminal)
    /// @dev    Quote at the forked block 18819734: 1 ETH = 2,242.42 DAI (DAI-WETH 0.005% Uni V3 pool). Max slippage suggested (uni sdk) 1,13%
    function testPayDaiSwapEthPayEth(
        uint256 _amountIn
    )
        external
    {   

        // Make a payment.
        _terminal.pay{value: _amountIn}({
            projectId: _projectId,
            amount: _amountIn,
            token: JBConstants.NATIVE_TOKEN, // Unused.
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "Take my money!",
            metadata: new bytes(0)
        });

        // Make sure the beneficiary has a balance of project tokens.
        uint256 _beneficiaryTokenBalance =
            UD60x18unwrap(UD60x18mul(UD60x18wrap(_nativePayAmount), UD60x18wrap(_data.weight)));
        assertEq(_tokens.totalBalanceOf(_beneficiary, _projectId), _beneficiaryTokenBalance);

        // Make sure the native token balance in terminal is up to date.
        uint256 _terminalBalance = _nativePayAmount;
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBConstants.NATIVE_TOKEN), _terminalBalance
        );

    }

    function _reconfigure() internal {
        JBRulesetMetadata private _metadata = JBRulesetMetadata({
            reservedRate: 0,
            redemptionRate: 0,
            baseCurrency: uint32(uint160(JBConstants.NATIVE_TOKEN)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowOwnerMinting: false,
            allowTerminalMigration: false,
            allowSetTerminals: true,
            allowControllerMigration: false,
            allowSetController: false,
            holdFees: false,
            useTotalSurplusForRedemptions: false,
            useDataHookForPay: false,
            useDataHookForRedeem: false,
            dataHook: address(0),
            metadata: 0
        });

        JBRuleset memory _ruleset = jbRulesets().currentOf(_projectId);

        // Package a ruleset configuration.
        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].duration = _ruleset.duration;
        _rulesetConfig[0].weight = 0;
        _rulesetConfig[0].decayRate = 0;
        _rulesetConfig[0].approvalHook = _deadline;
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = ruleset.splitGroup;
        _rulesetConfig[0].fundAccessLimitGroups = ruleset.fundAccessLimitGroup;

        vm.prank(multisig());
        _controller.queueRulesetsOf(_projectId, _rulesetConfig, "");

        vm.warp(block.timestamp + _ruleset.duration);

        // Set a new primary terminal for DAI
        _directory.setPrimaryTerminalOf(_projectId, DAI, _swapTerminal);
    }
}
