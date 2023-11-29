// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {JBBallotState} from "./../enums/JBBallotState.sol";
import {JBFundingCycle} from "./../structs/JBFundingCycle.sol";
import {JBFundingCycleConfig} from "./../structs/JBFundingCycleConfig.sol";
import {JBFundingCycleMetadata} from "./../structs/JBFundingCycleMetadata.sol";
import {JBProjectMetadata} from "./../structs/JBProjectMetadata.sol";
import {JBTerminalConfig} from "./../structs/JBTerminalConfig.sol";
import {JBSplit} from "./../structs/JBSplit.sol";
import {IJBDirectory} from "./IJBDirectory.sol";
import {IJBFundAccessConstraintsStore} from "./IJBFundAccessConstraintsStore.sol";
import {IJBFundingCycleStore} from "./IJBFundingCycleStore.sol";
import {IJBMigratable} from "./IJBMigratable.sol";
import {IJBProjects} from "./IJBProjects.sol";
import {IJBProjectMetadataRegistry} from "./IJBProjectMetadataRegistry.sol";
import {IJBSplitsStore} from "./IJBSplitsStore.sol";
import {IJBTokenStore} from "./IJBTokenStore.sol";
import {JBGroupedSplits} from "./../structs/JBGroupedSplits.sol";
import {IJBToken} from "./../interfaces/IJBToken.sol";

interface IJBController3_1 is IERC165, IJBProjectMetadataRegistry {
    event LaunchProject(
        uint256 configuration,
        uint256 projectId,
        JBProjectMetadata metadata,
        string memo,
        address caller
    );

    event LaunchFundingCycles(
        uint256 configuration, uint256 projectId, string memo, address caller
    );

    event ReconfigureFundingCycles(
        uint256 configuration, uint256 projectId, string memo, address caller
    );

    event DistributeReservedTokens(
        uint256 indexed fundingCycleConfiguration,
        uint256 indexed fundingCycleNumber,
        uint256 indexed projectId,
        address beneficiary,
        uint256 tokenCount,
        uint256 beneficiaryTokenCount,
        string memo,
        address caller
    );

    event DistributeToReservedTokenSplit(
        uint256 indexed projectId,
        uint256 indexed domain,
        uint256 indexed group,
        JBSplit split,
        uint256 tokenCount,
        address caller
    );

    event MintTokens(
        address indexed beneficiary,
        uint256 indexed projectId,
        uint256 tokenCount,
        uint256 beneficiaryTokenCount,
        string memo,
        uint256 reservedRate,
        address caller
    );

    event BurnTokens(
        address indexed holder,
        uint256 indexed projectId,
        uint256 tokenCount,
        string memo,
        address caller
    );

    event Migrate(uint256 indexed projectId, IJBMigratable to, address caller);

    event PrepMigration(uint256 indexed projectId, address from, address caller);

    event SetMetadata(uint256 indexed projectId, JBProjectMetadata metadata, address caller);

    function projects() external view returns (IJBProjects);

    function fundingCycleStore() external view returns (IJBFundingCycleStore);

    function tokenStore() external view returns (IJBTokenStore);

    function splitsStore() external view returns (IJBSplitsStore);

    function fundAccessConstraintsStore() external view returns (IJBFundAccessConstraintsStore);

    function directory() external view returns (IJBDirectory);

    function reservedTokenBalanceOf(uint256 projectId) external view returns (uint256);

    function totalOutstandingTokensOf(uint256 projectId) external view returns (uint256);

    function getFundingCycleOf(uint256 projectId, uint256 configuration)
        external
        view
        returns (JBFundingCycle memory fundingCycle, JBFundingCycleMetadata memory metadata);

    function latestConfiguredFundingCycleOf(uint256 projectId)
        external
        view
        returns (JBFundingCycle memory, JBFundingCycleMetadata memory metadata, JBBallotState);

    function currentFundingCycleOf(uint256 projectId)
        external
        view
        returns (JBFundingCycle memory fundingCycle, JBFundingCycleMetadata memory metadata);

    function queuedFundingCycleOf(uint256 projectId)
        external
        view
        returns (JBFundingCycle memory fundingCycle, JBFundingCycleMetadata memory metadata);

    function launchProjectFor(
        address owner,
        JBProjectMetadata calldata projectMetadata,
        JBFundingCycleConfig[] calldata fundingCycleConfigurations,
        JBTerminalConfig[] memory terminalConfigurations,
        string calldata memo
    ) external returns (uint256 projectId);

    function launchFundingCyclesFor(
        uint256 projectId,
        JBFundingCycleConfig[] calldata fundingCycleConfigurations,
        JBTerminalConfig[] memory terminalConfigurations,
        string calldata memo
    ) external returns (uint256 configured);

    function reconfigureFundingCyclesOf(
        uint256 projectId,
        JBFundingCycleConfig[] calldata fundingCycleConfigurations,
        string calldata memo
    ) external returns (uint256 configured);

    function mintTokensOf(
        uint256 projectId,
        uint256 tokenCount,
        address beneficiary,
        string calldata memo,
        bool useReservedRate
    ) external returns (uint256 beneficiaryTokenCount);

    function burnTokensOf(
        address holder,
        uint256 projectId,
        uint256 tokenCount,
        string calldata memo
    ) external;

    function distributeReservedTokensOf(uint256 projectId, string memory memo)
        external
        returns (uint256);

    function migrate(uint256 projectId, IJBMigratable to) external;

    function setSplitsOf(
        uint256 projectId,
        uint256 domain,
        JBGroupedSplits[] calldata groupedSplits
    ) external;

    function issueTokenFor(uint256 projectId, string calldata name, string calldata symbol)
        external
        returns (IJBToken token);

    function setTokenFor(uint256 _projectId, IJBToken _token) external;

    function claimFor(address holder, uint256 projectId, uint256 amount, address beneficiary)
        external;

    function transferFrom(address holder, uint256 projectId, address recipient, uint256 amount)
        external;
}
