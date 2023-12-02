// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";

// A project's rulesets can be queued, and re-queued as long as the current ruleset approval hook approves.
contract TestReconfigureProject_Local is TestBaseWorkflow {
    IJBController private _controller;
    JBProjectMetadata private _projectMetadata;
    JBRulesetData private _data;
    JBRulesetData private _dataQueue;
    JBRulesetMetadata private _metadata;
    JBDeadline private _deadline;
    JBSplitGroup[] private _splitGroup;
    JBFundAccessLimitGroup[] private _fundAccessLimitGroup;
    IJBTerminal private _terminal;

    uint256 private _DEADLINE_DURATION = 3 days;
    uint256 private _RULESET_DURATION = 6;

    function setUp() public override {
        super.setUp();

        _terminal = jbMultiTerminal();
        _controller = jbController();

        _projectMetadata = JBProjectMetadata({content: "myIPFSHash", domain: 1});
        _deadline = new JBDeadline(_DEADLINE_DURATION);
        _data = JBRulesetData({
            duration: _RULESET_DURATION * 1 days,
            weight: 1000 * 10 ** 18,
            decayRate: 0,
            approvalHook: _deadline
        });
        _dataQueue = JBRulesetData({
            duration: _RULESET_DURATION * 1 days,
            weight: 69 * 10 ** 18,
            decayRate: 0,
            approvalHook: JBDeadline(address(0))
        });
        _projectMetadata = JBProjectMetadata({content: "myIPFSHash", domain: 1});

        _metadata = JBRulesetMetadata({
            global: JBGlobalRulesetMetadata({
                allowSetTerminals: false,
                allowSetController: false,
                pauseTransfers: false
            }),
            reservedRate: 0,
            redemptionRate: 0,
            baseCurrency: uint32(uint160(JBTokenList.Native)),
            pausePay: false,
            allowDiscretionaryMinting: false,
            allowTerminalMigration: false,
            allowControllerMigration: false,
            holdFees: false,
            useTotalSurplusForRedemptions: false,
            useDataHookForPay: false,
            useDataHookForRedeem: false,
            dataHook: address(0),
            metadata: 0
        });
    }

    function launchProjectForTest() public returns (uint256) {
        // Package up ruleset configuration.
        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].data = _data;
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfig[0].fundAccessLimitGroup = new JBFundAccessLimitGroup[](0);

        // Package up terminal configuration.
        JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContextConfig[] memory _accountingContexts = new JBAccountingContextConfig[](1);
        _accountingContexts[0] = JBAccountingContextConfig({
            token: JBTokenList.Native,
            standard: JBTokenStandards.NATIVE
        });
        _terminalConfigurations[0] =
            JBTerminalConfig({terminal: _terminal, accountingContextConfigs: _accountingContexts});

        uint256 projectId = _controller.launchProjectFor({
            owner: address(multisig()),
            projectMetadata: _projectMetadata,
            rulesetConfigurations: _rulesetConfig,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });

        return projectId;
    }

    function testReconfigureProject() public {
        // Package a ruleset configuration.
        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].data = _data;
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = _splitGroup;
        _rulesetConfig[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        // Deploy a project.
        uint256 projectId = launchProjectForTest();

        // Keep a reference to the current ruleset.
        JBRuleset memory _ruleset = jbRulesets().currentOf(projectId);

        // Make sure the ruleset has a cycle number of 1.
        assertEq(_ruleset.cycleNumber, 1);
        // Make sure the ruleset's weight matches.
        assertEq(_ruleset.weight, _data.weight);

        // Keep a reference to the ruleset's ID.
        uint256 _currentRulesetId = _ruleset.rulesetId;

        // Increment the weight to create a difference.
        _rulesetConfig[0].data.weight = _rulesetConfig[0].data.weight + 1;

        // Add a ruleset.
        vm.prank(multisig());
        _controller.queueRulesetsOf(projectId, _rulesetConfig, "");

        // Make sure the current ruleset hasn't changed.
        _ruleset = jbRulesets().currentOf(projectId);
        assertEq(_ruleset.cycleNumber, 1);
        assertEq(_ruleset.rulesetId, _currentRulesetId);
        assertEq(_ruleset.weight, _data.weight);

        // Go to the start of the next ruleset.
        vm.warp(_ruleset.start + _ruleset.duration);

        // Get the current ruleset.
        JBRuleset memory _newRuleset = jbRulesets().currentOf(projectId);
        // It should be the second cycle.
        assertEq(_newRuleset.cycleNumber, 2);
        assertEq(_newRuleset.weight, _data.weight + 1);
        assertEq(_newRuleset.basedOnId, _currentRulesetId);
    }

    function testMultipleQueuedOnCycledOver() public {
        // Keep references to two different weights.
        uint256 _weightFirstQueued = 1234 * 10 ** 18;
        uint256 _weightSecondQueued = 6969 * 10 ** 18;

        // Launch a project.
        uint256 projectId = launchProjectForTest();

        // Keep a reference to the current ruleset.
        JBRuleset memory _ruleset = jbRulesets().currentOf(projectId);

        // Make sure the ruleset is correct.
        assertEq(_ruleset.cycleNumber, 1);
        assertEq(_ruleset.weight, _data.weight);

        // Keep a reference to the current ruleset ID.
        uint256 _currentRulesetId = _ruleset.rulesetId;

        // Jump to the next ruleset.
        vm.warp(block.timestamp + _ruleset.duration);

        // Package up a first ruleset configuration to queue.
        JBRulesetConfig[] memory _firstQueued = new JBRulesetConfig[](1);
        _firstQueued[0].mustStartAtOrAfter = 0;
        _firstQueued[0].data = JBRulesetData({
            duration: _RULESET_DURATION * 1 days,
            weight: _weightFirstQueued,
            decayRate: 0,
            approvalHook: _deadline
        }); // 3 day deadline duration.
        _firstQueued[0].metadata = _metadata;
        _firstQueued[0].splitGroups = _splitGroup;
        _firstQueued[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        // Queue.
        vm.prank(multisig());
        _controller.queueRulesetsOf(projectId, _firstQueued, "");

        // Package up another ruleset configuration to queue.
        JBRulesetConfig[] memory _secondQueued = new JBRulesetConfig[](1);
        _secondQueued[0].mustStartAtOrAfter = 0;
        _secondQueued[0].data = JBRulesetData({
            duration: _RULESET_DURATION * 1 days,
            weight: _weightSecondQueued,
            decayRate: 0,
            approvalHook: _deadline
        }); // 3 day deadline duration.
        _secondQueued[0].metadata = _metadata;
        _secondQueued[0].splitGroups = _splitGroup;
        _secondQueued[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        // Queue again
        vm.prank(multisig());
        _controller.queueRulesetsOf(projectId, _secondQueued, "");

        // Since the second ruleset was queued during the same block as the one prior, increment the ruleset ID.
        uint256 secondRulesetId = block.timestamp + 1;

        // The current ruleset should not have changed, still in ruleset #2, cycled over from ruleset #1.
        _ruleset = jbRulesets().currentOf(projectId);
        assertEq(_ruleset.cycleNumber, 2);
        assertEq(_ruleset.rulesetId, _currentRulesetId);
        assertEq(_ruleset.weight, _data.weight);

        // Jump to after the deadline has passed, but before the next ruleset.
        vm.warp(_ruleset.start + _ruleset.duration - 1);

        // Make sure the queued ruleset is the second one queued.
        JBRuleset memory queuedRuleset = jbRulesets().upcomingRulesetOf(projectId);
        assertEq(queuedRuleset.cycleNumber, 3);
        assertEq(queuedRuleset.rulesetId, secondRulesetId);
        assertEq(queuedRuleset.weight, _weightSecondQueued);

        // Go the the start of the queued ruleset.
        vm.warp(_ruleset.start + _ruleset.duration);

        // Make sure the second queued is now the current ruleset.
        JBRuleset memory _newRuleset = jbRulesets().currentOf(projectId);
        assertEq(_newRuleset.cycleNumber, 3);
        assertEq(_newRuleset.rulesetId, secondRulesetId);
        assertEq(_newRuleset.weight, _weightSecondQueued);
    }

    function testMultipleReconfigure(uint8 _deadlineDuration) public {
        // Create a deadline with the provided deadline duration.
        _deadline = new JBDeadline(_deadlineDuration);

        // Package the ruleset data.
        _data = JBRulesetData({
            duration: _RULESET_DURATION * 1 days,
            weight: 10_000 ether,
            decayRate: 0,
            approvalHook: _deadline
        });
        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].data = _data;
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = _splitGroup;
        _rulesetConfig[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        // Launch a project to test.
        uint256 projectId = launchProjectForTest();

        // Keep a reference to the initial, current, and queued rulesets.
        JBRuleset memory initialRuleset = jbRulesets().currentOf(projectId);
        JBRuleset memory currentRuleset = initialRuleset;
        JBRuleset memory upcomingRuleset = jbRulesets().upcomingRulesetOf(projectId);

        for (uint256 i = 0; i < _RULESET_DURATION + 1; i++) {
            // If the deadline is less than the ruleset's duration, make sure the current ruleset's weight is linearly decremented.
            if (_deadlineDuration + i * 1 days < currentRuleset.duration) {
                assertEq(currentRuleset.weight, initialRuleset.weight - i);
            }

            // Package up a new ruleset with a decremented weight.
            _data = JBRulesetData({
                duration: _RULESET_DURATION * 1 days,
                weight: initialRuleset.weight - (i + 1), // i+1 -> next ruleset
                decayRate: 0,
                approvalHook: _deadline
            });
            JBRulesetConfig[] memory _config = new JBRulesetConfig[](1);
            _config[0].mustStartAtOrAfter = 0;
            _config[0].data = _data;
            _config[0].metadata = _metadata;
            _config[0].splitGroups = _splitGroup;
            _config[0].fundAccessLimitGroup = _fundAccessLimitGroup;

            // Queue the ruleset.
            vm.prank(multisig());
            _controller.queueRulesetsOf(projectId, _config, "");

            // Get a reference to the current and upcoming rulesets.
            currentRuleset = jbRulesets().currentOf(projectId);
            upcomingRuleset = jbRulesets().upcomingRulesetOf(projectId);

            // Make sure the upcoming ruleset is the ruleset currently under the approval hook.
            assertEq(upcomingRuleset.weight, _data.weight);

            // If the full deadline duration included in the ruleset.
            if (
                _deadlineDuration == 0
                    || currentRuleset.duration % (_deadlineDuration + i * 1 days)
                        < currentRuleset.duration
            ) {
                // Make sure the current ruleset's weight is still linearly decremented.
                assertEq(currentRuleset.weight, initialRuleset.weight - i);

                // Shift forward the start of the deadline into the ruleset, one day at a time, from ruleset to ruleset.
                vm.warp(currentRuleset.start + currentRuleset.duration + i * 1 days);

                // Make sure what was the upcoming ruleset is now current.
                currentRuleset = jbRulesets().currentOf(projectId);
                assertEq(currentRuleset.weight, _data.weight);

                // Make the upcoming is the cycled over version of current.
                upcomingRuleset = jbRulesets().upcomingRulesetOf(projectId);
                assertEq(upcomingRuleset.weight, _data.weight);
            }
            // If the deadline duration is across many rulesets.
            else {
                // Make sure the current ruleset has cycled over.
                vm.warp(currentRuleset.start + currentRuleset.duration);
                assertEq(currentRuleset.weight, initialRuleset.weight - i);

                // Make sure the new ruleset has started once the deadline duration has passed.
                vm.warp(currentRuleset.start + currentRuleset.duration + _deadlineDuration);
                currentRuleset = jbRulesets().currentOf(projectId);
                assertEq(currentRuleset.weight, _data.weight);
            }
        }
    }

    function testLaunchProjectWrongApprovalHook() public {
        /// Package the configuration.
        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].data = _data;
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = _splitGroup;
        _rulesetConfig[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        // Launch the project.
        uint256 projectId = launchProjectForTest();

        // Package another with a bad approval hook.
        JBRulesetData memory _dataNew = JBRulesetData({
            duration: _RULESET_DURATION * 1 days,
            weight: 12_345 * 10 ** 18,
            decayRate: 0,
            approvalHook: IJBRulesetApprovalHook(address(6969)) // Wrong approval hook address.
        });

        vm.prank(multisig());
        vm.expectRevert(abi.encodeWithSignature("INVALID_RULESET_APPROVAL_HOOK()"));

        JBRulesetConfig[] memory _config = new JBRulesetConfig[](1);
        _config[0].mustStartAtOrAfter = 0;
        _config[0].data = _dataNew;
        _config[0].metadata = _metadata;
        _config[0].splitGroups = _splitGroup;
        _config[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        _controller.queueRulesetsOf(projectId, _config, "");
    }

    function testQueueShortDurationProject() public {
        uint256 _shortDuration = 5 minutes;

        // Package a ruleset reconfiguration.
        _data = JBRulesetData({
            duration: _shortDuration,
            weight: 10_000 * 10 ** 18,
            decayRate: 0,
            approvalHook: _deadline
        });
        _dataQueue = JBRulesetData({
            duration: _RULESET_DURATION * 1 days,
            weight: 69 * 10 ** 18,
            decayRate: 0,
            approvalHook: IJBRulesetApprovalHook(address(0))
        });
        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].data = _data;
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = _splitGroup;
        _rulesetConfig[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        // Launch a project to test.
        uint256 projectId = launchProjectForTest();

        // Get a reference to the current ruleset.
        JBRuleset memory _ruleset = jbRulesets().currentOf(projectId);

        // Make sure the current ruleset is correct.
        assertEq(_ruleset.cycleNumber, 1); // Ok.
        assertEq(_ruleset.weight, _data.weight);

        // Keep a reference to the current ruleset ID.
        uint256 _currentRulesetId = _ruleset.rulesetId;

        // Package up a reconfiguration.
        JBRulesetConfig[] memory _config = new JBRulesetConfig[](1);
        _config[0].mustStartAtOrAfter = 0;
        _config[0].data = _dataQueue;
        _config[0].metadata = _metadata;
        _config[0].splitGroups = _splitGroup;
        _config[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        // Submit the reconfiguration.
        vm.prank(multisig());
        _controller.queueRulesetsOf(projectId, _config, "");

        // Make sure the ruleset hasn't changed.
        _ruleset = jbRulesets().currentOf(projectId);
        assertEq(_ruleset.cycleNumber, 1);
        assertEq(_ruleset.rulesetId, _currentRulesetId);
        assertEq(_ruleset.weight, _data.weight);

        // Go the the second ruleset.
        vm.warp(_ruleset.start + _ruleset.duration);

        // Make sure the ruleset cycled over.
        JBRuleset memory _newRuleset = jbRulesets().currentOf(projectId);
        assertEq(_newRuleset.cycleNumber, 2);
        assertEq(_newRuleset.weight, _data.weight);

        // Go to the end of the deadline duration.
        vm.warp(_ruleset.start + _ruleset.duration + _DEADLINE_DURATION);

        // Make sure the queued cycle is in effect.
        _newRuleset = jbRulesets().currentOf(projectId);
        assertEq(
            _newRuleset.cycleNumber,
            _ruleset.cycleNumber + (_DEADLINE_DURATION / _shortDuration) + 1
        );
        assertEq(_newRuleset.weight, _dataQueue.weight);
    }

    function testQueueWithoutBallot() public {
        // Package ruleset data and config.
        _data = JBRulesetData({
            duration: 5 minutes,
            weight: 10_000 * 10 ** 18,
            decayRate: 0,
            approvalHook: IJBRulesetApprovalHook(address(0))
        });
        _dataQueue = JBRulesetData({
            duration: _RULESET_DURATION * 1 days,
            weight: 69 * 10 ** 18,
            decayRate: 0,
            approvalHook: IJBRulesetApprovalHook(address(0))
        });
        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].data = _data;
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = _splitGroup;
        _rulesetConfig[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        // Launch a project to test with.
        uint256 projectId = launchProjectForTest();

        // Get a reference to the current ruleset.
        JBRuleset memory _ruleset = jbRulesets().currentOf(projectId);

        // Make sure the ruleset is expected.
        assertEq(_ruleset.cycleNumber, 1);
        assertEq(_ruleset.weight, _data.weight);

        // Package a new config.
        JBRulesetConfig[] memory _config = new JBRulesetConfig[](1);

        _config[0].mustStartAtOrAfter = 0;
        _config[0].data = _dataQueue;
        _config[0].metadata = _metadata;
        _config[0].splitGroups = _splitGroup;
        _config[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        vm.prank(multisig());
        _controller.queueRulesetsOf(projectId, _config, "");

        // Make sure the ruleset hasn't changed.
        _ruleset = jbRulesets().currentOf(projectId);
        assertEq(_ruleset.cycleNumber, 1);
        assertEq(_ruleset.weight, _data.weight);

        // Make sure the ruleset has changed once the ruleset is over.
        vm.warp(_ruleset.start + _ruleset.duration);
        _ruleset = jbRulesets().currentOf(projectId);
        assertEq(_ruleset.cycleNumber, 2);
        assertEq(_ruleset.weight, _dataQueue.weight);
    }

    function testMixedStarts() public {
        // Keep references to our different weights for assertions.
        uint256 _weightInitial = 1000 * 10 ** 18;
        uint256 _weightFirstQueued = 1234 * 10 ** 18;
        uint256 _weightSecondQueued = 6969 * 10 ** 18;

        // Keep a reference to the expected ruleset IDs (timestamps).
        uint256 _initialRulesetId = block.timestamp;

        // Package up a config.
        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].data = JBRulesetData({
            duration: _RULESET_DURATION * 1 days,
            weight: _weightInitial,
            decayRate: 0,
            approvalHook: _deadline
        }); // 3 day deadline duration.
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = _splitGroup;
        _rulesetConfig[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        // Launch the project to test with.
        uint256 projectId = launchProjectForTest();

        // Get the ruleset.
        JBRuleset memory _ruleset = jbRulesets().currentOf(projectId);

        // Make sure the first ruleset has begun.
        assertEq(_ruleset.cycleNumber, 1);
        assertEq(_ruleset.weight, _weightInitial);
        assertEq(_ruleset.rulesetId, block.timestamp);

        // Package up a new config.
        JBRulesetConfig[] memory _firstQueued = new JBRulesetConfig[](1);
        _firstQueued[0].mustStartAtOrAfter = 0;
        _firstQueued[0].data = JBRulesetData({
            duration: _RULESET_DURATION * 1 days,
            weight: _weightFirstQueued,
            decayRate: 0,
            approvalHook: _deadline
        }); // 3 day deadline duration.
        _firstQueued[0].metadata = _metadata;
        _firstQueued[0].splitGroups = _splitGroup;
        _firstQueued[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        // Queue a ruleset to be overridden (will be in `ApprovalExpected` status of the approval hook).
        vm.prank(multisig());
        _controller.queueRulesetsOf(projectId, _firstQueued, "");

        // Make sure the ruleset is queued.
        JBRuleset memory _queued = jbRulesets().upcomingRulesetOf(projectId);
        assertEq(_queued.cycleNumber, 2);
        assertEq(_queued.rulesetId, _initialRulesetId + 1);
        assertEq(_queued.weight, _weightFirstQueued);

        // Package up another config.
        JBRulesetConfig[] memory _secondQueued = new JBRulesetConfig[](1);
        _secondQueued[0].mustStartAtOrAfter = block.timestamp + 9 days;
        _secondQueued[0].data = JBRulesetData({
            duration: _RULESET_DURATION * 1 days,
            weight: _weightSecondQueued,
            decayRate: 0,
            approvalHook: _deadline
        }); // 3 day deadline duration.
        _secondQueued[0].metadata = _metadata;
        _secondQueued[0].splitGroups = _splitGroup;
        _secondQueued[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        // Queue the ruleset.
        // Will follow the cycled over (ruleset #1) ruleset, after overriding the above config, because the first ruleset queued is in `ApprovalExpected` status (the 3 day deadline has not passed).
        // Ruleset #1 rolls over because our `mustStartAtOrAfter` occurs later than when ruleset #1 ends.
        vm.prank(multisig());
        _controller.queueRulesetsOf(projectId, _secondQueued, "");

        // Make sure this latest queued ruleset implies a cycled over ruleset from ruleset #1.
        JBRuleset memory _requeued = jbRulesets().upcomingRulesetOf(projectId);
        assertEq(_requeued.cycleNumber, 2);
        assertEq(_requeued.rulesetId, _initialRulesetId);
        assertEq(_requeued.weight, _weightInitial);

        // Warp to when the initial ruleset rolls over and again becomes the current.
        vm.warp(block.timestamp + _RULESET_DURATION * 1 days);

        // Make sure the new current is a rolled over ruleset.
        JBRuleset memory _initialIsCurrent = jbRulesets().currentOf(projectId);
        assertEq(_initialIsCurrent.cycleNumber, 2);
        assertEq(_initialIsCurrent.rulesetId, _initialRulesetId);
        assertEq(_initialIsCurrent.weight, _weightInitial);

        // Second queued ruleset that replaced our first queued ruleset.
        JBRuleset memory _requeued2 = jbRulesets().upcomingRulesetOf(projectId);
        assertEq(_requeued2.cycleNumber, 3);
        assertEq(_requeued2.rulesetId, _initialRulesetId + 2);
        assertEq(_requeued2.weight, _weightSecondQueued);
    }

    function testSingleBlockOverwriteQueued() public {
        // Keep references to our different weights for assertions.
        uint256 _weightFirstQueued = 1234 * 10 ** 18;
        uint256 _weightSecondQueued = 6969 * 10 ** 18;

        // Keep a reference to the expected ruleset ID (timestamp) after queuing, starting now, incremented later in-line for readability.
        uint256 _expectedRulesetId = block.timestamp;

        // Package up a config.
        JBRulesetConfig[] memory _rulesetConfig = new JBRulesetConfig[](1);
        _rulesetConfig[0].mustStartAtOrAfter = 0;
        _rulesetConfig[0].data = _data;
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = _splitGroup;
        _rulesetConfig[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        // Deploy a project to test.
        uint256 projectId = launchProjectForTest();

        // Keep a reference to the current ruleset.
        JBRuleset memory _ruleset = jbRulesets().currentOf(projectId);

        // Initial ruleset data: will have a `block.timestamp` (`rulesetId`) that is 2 less than the second queued ruleset (`rulesetId` timestamps are incremented when queued in same block).
        assertEq(_ruleset.cycleNumber, 1);
        assertEq(_ruleset.weight, _data.weight);

        // Package up another config.
        JBRulesetConfig[] memory _firstQueued = new JBRulesetConfig[](1);
        _firstQueued[0].mustStartAtOrAfter = block.timestamp + 3 days;
        _firstQueued[0].data = JBRulesetData({
            duration: _RULESET_DURATION * 1 days,
            weight: _weightFirstQueued,
            decayRate: 0,
            approvalHook: _deadline
        }); // 3 day deadline duration.
        _firstQueued[0].metadata = _metadata;
        _firstQueued[0].splitGroups = _splitGroup;
        _firstQueued[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        // Becomes queued & will be overwritten as 3 days will not pass and its status is `ApprovalExpected`.
        vm.prank(multisig());
        _controller.queueRulesetsOf(projectId, _firstQueued, "");

        // Get a reference to the queued cycle.
        JBRuleset memory queuedToOverwrite = jbRulesets().upcomingRulesetOf(projectId);

        assertEq(queuedToOverwrite.cycleNumber, 2);
        assertEq(queuedToOverwrite.rulesetId, _expectedRulesetId + 1);
        assertEq(queuedToOverwrite.weight, _weightFirstQueued);

        // Package up another config to overwrite.
        JBRulesetConfig[] memory _secondQueued = new JBRulesetConfig[](1);

        _secondQueued[0].mustStartAtOrAfter = block.timestamp + _DEADLINE_DURATION;
        _secondQueued[0].data = JBRulesetData({
            duration: _RULESET_DURATION * 1 days,
            weight: _weightSecondQueued,
            decayRate: 0,
            approvalHook: _deadline
        }); // 3 day deadline duration.
        _secondQueued[0].metadata = _metadata;
        _secondQueued[0].splitGroups = _splitGroup;
        _secondQueued[0].fundAccessLimitGroup = _fundAccessLimitGroup;

        // Queuing the second ruleset will overwrite the first queued ruleset.
        vm.prank(multisig());
        _controller.queueRulesetsOf(projectId, _secondQueued, "");

        // Make sure it's overwritten.
        JBRuleset memory queued = jbRulesets().upcomingRulesetOf(projectId);
        assertEq(queued.cycleNumber, 2);
        assertEq(queued.rulesetId, _expectedRulesetId + 2);
        assertEq(queued.weight, _weightSecondQueued);
    }

    function testApprovalHook(uint256 _start, uint256 _rulesetId, uint256 _duration) public {
        _start = bound(_start, block.timestamp, block.timestamp + 1000 days);
        _rulesetId = bound(_rulesetId, block.timestamp, block.timestamp + 1000 days);
        _duration = bound(_duration, 1, block.timestamp);

        JBDeadline deadline = new JBDeadline(_duration);

        JBApprovalStatus _currentStatus = deadline.approvalStatusOf(1, _rulesetId, _start); // 1 is the `projectId`, unused

        // Ruleset ID (timestamp) is after deadline -> approval hook failed.
        if (_rulesetId > _start) {
            assertEq(uint256(_currentStatus), uint256(JBApprovalStatus.Failed));
        }
        // Deadline starts less than a `duration` away from the `rulesetId` -> failed (would start mid-ruleset).
        else if (_start - _duration < _rulesetId) {
            assertEq(uint256(_currentStatus), uint256(JBApprovalStatus.Failed));
        }
        // Deadline starts more than a `_duration` away (will be approved when enough time has passed) -> approval expected.
        else if (block.timestamp + _duration < _start) {
            assertEq(uint256(_currentStatus), uint256(JBApprovalStatus.ApprovalExpected));
        }
        // If enough time has passed since deadline start, approved.
        else if (block.timestamp + _duration > _start) {
            assertEq(uint256(_currentStatus), uint256(JBApprovalStatus.Approved));
        }
    }
}
