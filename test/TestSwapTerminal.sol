// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";

import {JBSwapTerminal} from "../src/JBSwapTerminal.sol";
import {IWETH9} from "../src/interfaces/external/IWETH9.sol";

import {MetadataResolverHelper} from "./helpers/MetadataResolverHelper.sol";

/// @notice Swap terminal test on a mainnet fork
contract TestSwapTerminal_Fork is TestBaseWorkflow {
    IERC20Metadata constant UNI = IERC20Metadata(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);
    IWETH9 constant WETH = IWETH9(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14);
    IUniswapV3Pool constant POOL = IUniswapV3Pool(0x287B0e934ed0439E2a7b1d5F0FC25eA2c24b64f7);

    JBSwapTerminal internal _swapTerminal;
    JBMultiTerminal internal _projectTerminal;
    JBTokens internal _tokens;
    IJBProjects internal _projects;
    IJBPermissions internal _permissions;
    IJBDirectory internal _directory;
    IPermit2 internal _permit2;
    IJBController internal _controller;
    JBTerminalStore internal _terminalStore;

    address internal _owner;
    address internal _sender;

    uint256 internal _projectId = 4;
    address internal _projectOwner;
    address internal _terminalOwner;
    address internal _beneficiary;

    MetadataResolverHelper internal _metadataResolver;

    function setUp() public override {
        vm.createSelectFork("https://rpc.ankr.com/eth_sepolia", 5_022_528);

        vm.label(address(UNI), "UNI");
        vm.label(address(WETH), "WETH");
        vm.label(address(POOL), "POOL");

        // TODO: find a new way to parse broadcast json
        // _controller = IJBController(stdJson.readAddress(
        //         vm.readFile("broadcast/Deploy.s.sol/11155420/run-latest.json"), ".address"
        //     ));

        _controller = IJBController(0x15e9030Dd25b27d7e6763598B87445daf222C115);
        vm.label(address(_controller), "controller");

        _projects = IJBProjects(0x95df60b57Ee581680F5c243554E16BD4F3A6a192);
        vm.label(address(_projects), "projects");

        _permissions = IJBPermissions(0x607763b1458419Edb09f56CE795057A2958e2001);
        vm.label(address(_permissions), "permissions");

        _directory = IJBDirectory(0x862ea57d0C473a5c7c8330d92C7824dbd60269EC);
        vm.label(address(_directory), "directory");

        _permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
        vm.label(address(_permit2), "permit2");

        _tokens = JBTokens(0xdb42B6D08755c3f09AdB8C35A19A558bc1b40C9b);
        vm.label(address(_tokens), "tokens");

        _terminalStore = JBTerminalStore(0x6b2c93da6Af4061Eb6dAe4aCFc15632b54c37DE5);
        vm.label(address(_terminalStore), "terminalStore");

        _projectTerminal = JBMultiTerminal(0x4319cb152D46Db72857AfE368B19A4483c0Bff0D);
        vm.label(address(_projectTerminal), "projectTerminal");

        _owner = makeAddr("owner");
        _sender = makeAddr("sender");

        _projectOwner = _projects.ownerOf(_projectId);
        vm.label(_projectOwner, "projectOwner");

        _swapTerminal = new JBSwapTerminal(_projects, _permissions, _directory, _permit2, _owner, WETH);
        vm.label(address(_swapTerminal), "swapTerminal");

        _metadataResolver = new MetadataResolverHelper();
        vm.label(address(_metadataResolver), "metadataResolver");
    }

    /// @notice Test paying a swap terminal in UNI to contribute to JuiceboxDAO project (in the eth terminal), using
    /// metadata
    /// @dev    Quote at the forked block 5022528 : 1 UNI = 1.33649 ETH with max slippage suggested (uni sdk): 0.5%
    function testPayUniSwapEthPayEth() external {
        // NOTE: bullet proofing for coming fuzzed token
        uint256 _amountIn = 10 * 10 ** UNI.decimals();

        deal(address(UNI), address(_sender), _amountIn);

        // 10 uni - 8%
        uint256 _minAmountOut = 10 * 1.33649 ether * 92 / 100;

        vm.prank(_projectOwner);
        _swapTerminal.addDefaultPool(_projectId, address(UNI), POOL);

        // Build the metadata using the minimum amount out, the pool address and the token out address
        bytes[] memory _data = new bytes[](1);
        _data[0] = abi.encode(_minAmountOut, address(POOL), JBConstants.NATIVE_TOKEN);

        // Pass the delegate id
        bytes4[] memory _ids = new bytes4[](1);
        _ids[0] = bytes4("SWAP");

        // Generate the metadata
        bytes memory _metadata = _metadataResolver.createMetadata(_ids, _data);

        // Approve the transfer
        vm.startPrank(_sender);
        UNI.approve(address(_swapTerminal), _amountIn);

        // Make a payment.
        _swapTerminal.pay({
            _projectId: _projectId,
            _amount: _amountIn,
            _token: address(UNI),
            _beneficiary: _beneficiary,
            _minReturnedTokens: 1,
            _memo: "Take my money!",
            _metadata: _metadata
        });

        // // Make sure the beneficiary has a balance of project tokens.
        // uint256 _beneficiaryTokenBalance =
        //     UD60x18unwrap(UD60x18mul(UD60x18wrap(_amountIn * _quote), UD60x18wrap(_weight)));
        // assertEq(_tokens.totalBalanceOf(_beneficiary, _projectId), _beneficiaryTokenBalance);

        // // Make sure the native token balance in terminal is up to date.
        // uint256 _terminalBalance = _amountIn * _quote;
        // assertEq(
        //     jbTerminalStore().balanceOf(address(_projectTerminal), _projectId, JBConstants.NATIVE_TOKEN),
        // _terminalBalance
        // );
    }

    function _reconfigure() internal {
        JBRulesetMetadata memory _metadata = JBRulesetMetadata({
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
        _rulesetConfig[0].approvalHook = IJBRulesetApprovalHook(address(0));
        _rulesetConfig[0].metadata = _metadata;
        _rulesetConfig[0].splitGroups = new JBSplitGroup[](0);
        _rulesetConfig[0].fundAccessLimitGroups = new JBFundAccessLimitGroup[](0);

        vm.prank(multisig());
        _controller.queueRulesetsOf(_projectId, _rulesetConfig, "");

        vm.warp(block.timestamp + _ruleset.duration);

        // Set a new primary terminal for UNI
        _directory.setPrimaryTerminalOf(_projectId, address(UNI), _swapTerminal);
    }
}
