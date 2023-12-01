// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import {PRBMath} from "@paulrberg/contracts/math/PRBMath.sol";
import {JBOperatable} from "./abstract/JBOperatable.sol";
import {JBBallotState} from "./enums/JBBallotState.sol";
import {IJBController3_1} from "./interfaces/IJBController3_1.sol";
import {IJBDirectory} from "./interfaces/IJBDirectory.sol";
import {IJBFundAccessConstraintsStore} from "./interfaces/IJBFundAccessConstraintsStore.sol";
import {IJBFundingCycleStore} from "./interfaces/IJBFundingCycleStore.sol";
import {IJBDirectoryAccessControl} from "./interfaces/IJBDirectoryAccessControl.sol";
import {IJBMigratable} from "./interfaces/IJBMigratable.sol";
import {IJBOperatable} from "./interfaces/IJBOperatable.sol";
import {IJBOperatorStore} from "./interfaces/IJBOperatorStore.sol";
import {IJBPaymentTerminal} from "./interfaces/terminal/IJBPaymentTerminal.sol";
import {IJBProjects} from "./interfaces/IJBProjects.sol";
import {IJBProjectMetadataRegistry} from "./interfaces/IJBProjectMetadataRegistry.sol";
import {IJBSplitAllocator} from "./interfaces/IJBSplitAllocator.sol";
import {IJBSplitsStore} from "./interfaces/IJBSplitsStore.sol";
import {IJBTokenStore} from "./interfaces/IJBTokenStore.sol";
import {IJBToken} from "./interfaces/IJBToken.sol";
import {IJBPriceFeed} from "./interfaces/IJBPriceFeed.sol";
import {JBConstants} from "./libraries/JBConstants.sol";
import {JBFundingCycleMetadataResolver} from "./libraries/JBFundingCycleMetadataResolver.sol";
import {JBOperations} from "./libraries/JBOperations.sol";
import {JBSplitsGroups} from "./libraries/JBSplitsGroups.sol";
import {JBFundingCycle} from "./structs/JBFundingCycle.sol";
import {JBFundingCycleConfig} from "./structs/JBFundingCycleConfig.sol";
import {JBFundingCycleMetadata} from "./structs/JBFundingCycleMetadata.sol";
import {JBTerminalConfig} from "./structs/JBTerminalConfig.sol";
import {JBSplit} from "./structs/JBSplit.sol";
import {JBSplitAllocationData} from "./structs/JBSplitAllocationData.sol";
import {JBGroupedSplits} from "./structs/JBGroupedSplits.sol";

/// @notice Stitches together funding cycles and project tokens, making sure all activity is accounted for and correct.
contract JBController3_1 is
    JBOperatable,
    ERC2771Context,
    ERC165,
    IJBController3_1,
    IJBMigratable
{
    // A library that parses the packed funding cycle metadata into a more friendly format.
    using JBFundingCycleMetadataResolver for JBFundingCycle;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error BURN_PAUSED_AND_SENDER_NOT_VALID_TERMINAL_DELEGATE();
    error FUNDING_CYCLE_ALREADY_LAUNCHED();
    error INVALID_BASE_CURRENCY();
    error INVALID_REDEMPTION_RATE();
    error INVALID_RESERVED_RATE();
    error MIGRATION_NOT_ALLOWED();
    error MINT_NOT_ALLOWED_AND_NOT_TERMINAL_DELEGATE();
    error NO_BURNABLE_TOKENS();
    error NOT_CURRENT_CONTROLLER();
    error TRANSFERS_PAUSED();
    error ZERO_TOKENS_TO_MINT();

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice Mints ERC-721's that represent project ownership.
    IJBProjects public immutable override projects;

    /// @notice The contract storing all funding cycle configurations.
    IJBFundingCycleStore public immutable override fundingCycleStore;

    /// @notice The contract that manages token minting and burning.
    IJBTokenStore public immutable override tokenStore;

    /// @notice The contract that stores splits for each project.
    IJBSplitsStore public immutable override splitsStore;

    /// @notice A contract that stores fund access constraints for each project.
    IJBFundAccessConstraintsStore public immutable override fundAccessConstraintsStore;

    /// @notice The directory of terminals and controllers for projects.
    IJBDirectory public immutable override directory;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The current undistributed reserved token balance of.
    mapping(uint256 => uint256) public override reservedTokenBalanceOf;

    /// @notice The metadata for each project, which can be used across several domains.
    /// @custom:param _projectId The ID of the project to which the metadata belongs.
    mapping(uint256 => string) public override metadataOf;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Gets the current total amount of outstanding tokens for a project.
    /// @param _projectId The ID of the project to get total outstanding tokens of.
    /// @return The current total amount of outstanding tokens for the project.
    function totalOutstandingTokensOf(uint256 _projectId)
        external
        view
        override
        returns (uint256)
    {
        // Add the reserved tokens to the total supply.
        return tokenStore.totalSupplyOf(_projectId) + reservedTokenBalanceOf[_projectId];
    }

    /// @notice A project's funding cycle for the specified configuration along with its metadata.
    /// @param _projectId The ID of the project to which the funding cycle belongs.
    /// @return fundingCycle The funding cycle.
    /// @return metadata The funding cycle's metadata.
    function getFundingCycleOf(uint256 _projectId, uint256 _configuration)
        external
        view
        override
        returns (JBFundingCycle memory fundingCycle, JBFundingCycleMetadata memory metadata)
    {
        fundingCycle = fundingCycleStore.get(_projectId, _configuration);
        metadata = fundingCycle.expandMetadata();
    }

    /// @notice A project's latest configured funding cycle along with its metadata and the ballot state of the configuration.
    /// @param _projectId The ID of the project to which the funding cycle belongs.
    /// @return fundingCycle The latest configured funding cycle.
    /// @return metadata The latest configured funding cycle's metadata.
    /// @return ballotState The state of the configuration.
    function latestConfiguredFundingCycleOf(uint256 _projectId)
        external
        view
        override
        returns (
            JBFundingCycle memory fundingCycle,
            JBFundingCycleMetadata memory metadata,
            JBBallotState ballotState
        )
    {
        (fundingCycle, ballotState) = fundingCycleStore.latestConfiguredOf(_projectId);
        metadata = fundingCycle.expandMetadata();
    }

    /// @notice A project's current funding cycle along with its metadata.
    /// @param _projectId The ID of the project to which the funding cycle belongs.
    /// @return fundingCycle The current funding cycle.
    /// @return metadata The current funding cycle's metadata.
    function currentFundingCycleOf(uint256 _projectId)
        external
        view
        override
        returns (JBFundingCycle memory fundingCycle, JBFundingCycleMetadata memory metadata)
    {
        fundingCycle = fundingCycleStore.currentOf(_projectId);
        metadata = fundingCycle.expandMetadata();
    }

    /// @notice A project's queued funding cycle along with its metadata.
    /// @param _projectId The ID of the project to which the funding cycle belongs.
    /// @return fundingCycle The queued funding cycle.
    /// @return metadata The queued funding cycle's metadata.
    function queuedFundingCycleOf(uint256 _projectId)
        external
        view
        override
        returns (JBFundingCycle memory fundingCycle, JBFundingCycleMetadata memory metadata)
    {
        fundingCycle = fundingCycleStore.queuedOf(_projectId);
        metadata = fundingCycle.expandMetadata();
    }

    /// @notice A flag indicating if the project currently allows terminals to be set.
    /// @param _projectId The ID of the project the flag is for.
    /// @return The flag
    function setTerminalsAllowed(uint256 _projectId) external view returns (bool) {
        return fundingCycleStore.currentOf(_projectId).expandMetadata().allowSetTerminals;
    }

    /// @notice A flag indicating if the project currently allows its controller to be set.
    /// @param _projectId The ID of the project the flag is for.
    /// @return The flag
    function setControllerAllowed(uint256 _projectId) external view returns (bool) {
        return fundingCycleStore.currentOf(_projectId).expandMetadata().allowSetController;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param _interfaceId The ID of the interface to check for adherance to.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 _interfaceId)
        public
        view
        virtual
        override(ERC165, IERC165)
        returns (bool)
    {
        return _interfaceId == type(IJBController3_1).interfaceId
            || _interfaceId == type(IJBProjectMetadataRegistry).interfaceId
            || _interfaceId == type(IJBDirectoryAccessControl).interfaceId
            || _interfaceId == type(IJBMigratable).interfaceId
            || _interfaceId == type(IJBOperatable).interfaceId || super.supportsInterface(_interfaceId);
    }

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param _projects A contract which mints ERC-721's that represent project ownership and transfers.
    /// @param _directory A contract storing directories of terminals and controllers for each project.
    /// @param _fundingCycleStore A contract storing all funding cycle configurations.
    /// @param _tokenStore A contract that manages token minting and burning.
    /// @param _splitsStore A contract that stores splits for each project.
    /// @param _fundAccessConstraintsStore A contract that stores fund access constraints for each project.
    constructor(
        IJBDirectory _directory,
        IJBFundAccessConstraintsStore _fundAccessConstraintsStore,
        address _trustedForwarder
    ) JBOperatable(_directory.operatorStore()) ERC2771Context(_trustedForwarder) {
        directory = _directory;
        fundAccessConstraintsStore = _fundAccessConstraintsStore;
        projects = _directory.projects();
        fundingCycleStore = _directory.fundingCycleStore();
        tokenStore = _directory.tokenStore();
        splitsStore = _directory.splitsStore();
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Creates a project. This will mint an ERC-721 into the specified owner's account, configure a first funding cycle, and set up any splits.
    /// @dev Each operation within this transaction can be done in sequence separately.
    /// @dev Anyone can deploy a project on an owner's behalf.
    /// @param _owner The address to set as the owner of the project. The project ERC-721 will be owned by this address.
    /// @param _projectMetadata Metadata to associate with the project. This can be updated any time by the owner of the project.
    /// @param _fundingCycleConfigurations The funding cycle configurations to schedule.
    /// @param _terminalConfigurations The terminal configurations to add for the project.
    /// @param _memo A memo to pass along to the emitted event.
    /// @return projectId The ID of the project.
    function launchProjectFor(
        address _owner,
        string calldata _projectMetadata,
        JBFundingCycleConfig[] calldata _fundingCycleConfigurations,
        JBTerminalConfig[] calldata _terminalConfigurations,
        string memory _memo
    ) external virtual override returns (uint256 projectId) {
        // Keep a reference to the directory.
        IJBDirectory _directory = directory;

        // Mint the project into the wallet of the owner.
        projectId = projects.createFor(_owner);

        // Set project metadata if one was provided.
        if (bytes(_projectMetadata).length > 0) {
            metadataOf[projectId] = _projectMetadata;
        }

        // Set this contract as the project's controller in the directory.
        _directory.setControllerOf(projectId, IERC165(this));

        // Configure the first funding cycle.
        uint256 _configuration = _configureFundingCycles(projectId, _fundingCycleConfigurations);

        // Configure the terminals.
        _configureTerminals(projectId, _terminalConfigurations);

        emit LaunchProject(_configuration, projectId, _projectMetadata, _memo, _msgSender());
    }

    /// @notice Creates a funding cycle for an already existing project ERC-721.
    /// @dev Each operation within this transaction can be done in sequence separately.
    /// @dev Only a project owner or operator can launch its funding cycles.
    /// @param _projectId The ID of the project to launch funding cycles for.
    /// @param _fundingCycleConfigurations The funding cycle configurations to schedule.
    /// @param _terminalConfigurations The terminal configurations to add for the project.
    /// @param _memo A memo to pass along to the emitted event.
    /// @return configured The configuration timestamp of the funding cycle that was successfully reconfigured.
    function launchFundingCyclesFor(
        uint256 _projectId,
        JBFundingCycleConfig[] calldata _fundingCycleConfigurations,
        JBTerminalConfig[] calldata _terminalConfigurations,
        string memory _memo
    )
        external
        virtual
        override
        requirePermission(
            projects.ownerOf(_projectId),
            _projectId,
            JBOperations.RECONFIGURE_FUNDING_CYCLES
        )
        returns (uint256 configured)
    {
        // If there is a previous configuration, reconfigureFundingCyclesOf should be called instead
        if (fundingCycleStore.latestConfigurationOf(_projectId) > 0) {
            revert FUNDING_CYCLE_ALREADY_LAUNCHED();
        }

        // Set this contract as the project's controller in the directory.
        directory.setControllerOf(_projectId, IERC165(this));

        // Configure the first funding cycle.
        configured = _configureFundingCycles(_projectId, _fundingCycleConfigurations);

        // Configure the terminals.
        _configureTerminals(_projectId, _terminalConfigurations);

        emit LaunchFundingCycles(configured, _projectId, _memo, _msgSender());
    }

    /// @notice Proposes a configuration of a subsequent funding cycle that will take effect once the current one expires if it is approved by the current funding cycle's ballot.
    /// @dev Only a project's owner or a designated operator can configure its funding cycles.
    /// @param _projectId The ID of the project whose funding cycles are being reconfigured.
    /// @param _fundingCycleConfigurations The funding cycle configurations to schedule.
    /// @param _memo A memo to pass along to the emitted event.
    /// @return configured The configuration timestamp of the funding cycle that was successfully reconfigured.
    function reconfigureFundingCyclesOf(
        uint256 _projectId,
        JBFundingCycleConfig[] calldata _fundingCycleConfigurations,
        string calldata _memo
    )
        external
        virtual
        override
        requirePermission(
            projects.ownerOf(_projectId),
            _projectId,
            JBOperations.RECONFIGURE_FUNDING_CYCLES
        )
        returns (uint256 configured)
    {
        // Configure the next funding cycle.
        configured = _configureFundingCycles(_projectId, _fundingCycleConfigurations);

        emit ReconfigureFundingCycles(configured, _projectId, _memo, _msgSender());
    }

    /// @notice Mint new token supply into an account, and optionally reserve a supply to be distributed according to the project's current funding cycle configuration.
    /// @dev Only a project's owner, a designated operator, one of its terminals, or the current data source can mint its tokens.
    /// @param _projectId The ID of the project to which the tokens being minted belong.
    /// @param _tokenCount The amount of tokens to mint in total, counting however many should be reserved.
    /// @param _beneficiary The account that the tokens are being minted for.
    /// @param _memo A memo to pass along to the emitted event.
    /// @param _useReservedRate Whether to use the current funding cycle's reserved rate in the mint calculation.
    /// @return beneficiaryTokenCount The amount of tokens minted for the beneficiary.
    function mintTokensOf(
        uint256 _projectId,
        uint256 _tokenCount,
        address _beneficiary,
        string calldata _memo,
        bool _useReservedRate
    ) external virtual override returns (uint256 beneficiaryTokenCount) {
        // There should be tokens to mint.
        if (_tokenCount == 0) revert ZERO_TOKENS_TO_MINT();

        // Define variables that will be needed outside scoped section below.
        // Keep a reference to the reserved rate to use
        uint256 _reservedRate;

        // Scoped section prevents stack too deep. `_fundingCycle` only used within scope.
        {
            // Get a reference to the project's current funding cycle.
            JBFundingCycle memory _fundingCycle = fundingCycleStore.currentOf(_projectId);

            // Minting limited to: project owner, authorized callers, project terminal and current funding cycle data source
            _requirePermissionAllowingOverride(
                projects.ownerOf(_projectId),
                _projectId,
                JBOperations.MINT_TOKENS,
                directory.isTerminalOf(_projectId, IJBPaymentTerminal(_msgSender()))
                    || _msgSender() == address(_fundingCycle.dataSource())
            );

            // If the message sender is not a terminal or a datasource, the current funding cycle must allow minting.
            if (
                !_fundingCycle.mintingAllowed()
                    && !directory.isTerminalOf(_projectId, IJBPaymentTerminal(_msgSender()))
                    && _msgSender() != address(_fundingCycle.dataSource())
            ) revert MINT_NOT_ALLOWED_AND_NOT_TERMINAL_DELEGATE();

            // Determine the reserved rate to use.
            _reservedRate = _useReservedRate ? _fundingCycle.reservedRate() : 0;
        }

        if (_reservedRate != JBConstants.MAX_RESERVED_RATE) {
            // The unreserved token count that will be minted for the beneficiary.
            beneficiaryTokenCount = PRBMath.mulDiv(
                _tokenCount,
                JBConstants.MAX_RESERVED_RATE - _reservedRate,
                JBConstants.MAX_RESERVED_RATE
            );

            // Mint the tokens.
            tokenStore.mintFor(_beneficiary, _projectId, beneficiaryTokenCount);
        }

        // Add reserved tokens if needed
        if (_reservedRate > 0) {
            reservedTokenBalanceOf[_projectId] += _tokenCount - beneficiaryTokenCount;
        }

        emit MintTokens(
            _beneficiary,
            _projectId,
            _tokenCount,
            beneficiaryTokenCount,
            _memo,
            _reservedRate,
            _msgSender()
        );
    }

    /// @notice Burns a token holder's supply.
    /// @dev Only a token's holder, a designated operator, or a project's terminal can burn it.
    /// @param _holder The account that is having its tokens burned.
    /// @param _projectId The ID of the project to which the tokens being burned belong.
    /// @param _tokenCount The number of tokens to burn.
    /// @param _memo A memo to pass along to the emitted event.
    function burnTokensOf(
        address _holder,
        uint256 _projectId,
        uint256 _tokenCount,
        string calldata _memo
    )
        external
        virtual
        override
        requirePermissionAllowingOverride(
            _holder,
            _projectId,
            JBOperations.BURN_TOKENS,
            directory.isTerminalOf(_projectId, IJBPaymentTerminal(_msgSender()))
        )
    {
        // There should be tokens to burn
        if (_tokenCount == 0) revert NO_BURNABLE_TOKENS();

        // Burn the tokens.
        tokenStore.burnFrom(_holder, _projectId, _tokenCount);

        emit BurnTokens(_holder, _projectId, _tokenCount, _memo, _msgSender());
    }

    /// @notice Distributes all outstanding reserved tokens for a project.
    /// @param _projectId The ID of the project to which the reserved tokens belong.
    /// @param _memo A memo to pass along to the emitted event.
    /// @return The amount of minted reserved tokens.
    function distributeReservedTokensOf(uint256 _projectId, string calldata _memo)
        external
        virtual
        override
        returns (uint256)
    {
        return _distributeReservedTokensOf(_projectId, _memo);
    }

    /// @notice Allows other controllers to signal to this one that a migration is expected for the specified project.
    /// @dev This controller should not yet be the project's controller.
    /// @param _from The controller being migrated from.
    /// @param _projectId The ID of the project that will be migrated to this controller.
    function receiveMigrationFrom(IERC165 _from, uint256 _projectId) external virtual override {
        _projectId; // Prevents unused var compiler and natspec complaints.
        _from; // Prevents unused var compiler and natspec complaints.

        // Copy the main metadata if relevant.
        if (
            _from.supportsInterface(type(IJBProjectMetadataRegistry).interfaceId)
                && directory.controllerOf(_projectId) == _from
        ) {
            metadataOf[_projectId] =
                IJBProjectMetadataRegistry(address(_from)).metadataOf(_projectId);
        }
    }

    /// @notice Allows a project to migrate from this controller to another.
    /// @dev Only a project's owner or a designated operator can migrate it.
    /// @param _projectId The ID of the project that will be migrated from this controller.
    /// @param _to The controller to which the project is migrating.
    function migrate(uint256 _projectId, IJBMigratable _to)
        external
        virtual
        override
        requirePermission(projects.ownerOf(_projectId), _projectId, JBOperations.MIGRATE_CONTROLLER)
    {
        // Keep a reference to the directory.
        IJBDirectory _directory = directory;

        // Get a reference to the project's current funding cycle.
        JBFundingCycle memory _fundingCycle = fundingCycleStore.currentOf(_projectId);

        // Migration must be allowed.
        if (!_fundingCycle.controllerMigrationAllowed()) revert MIGRATION_NOT_ALLOWED();

        // All reserved tokens must be minted before migrating.
        if (reservedTokenBalanceOf[_projectId] != 0) _distributeReservedTokensOf(_projectId, "");

        // Make sure the new controller is prepped for the migration.
        _to.receiveMigrationFrom(IERC165(this), _projectId);

        emit Migrate(_projectId, _to, _msgSender());
    }

    /// @notice Allows a project owner to set the project's metadata content for a particular domain namespace.
    /// @dev Only a project's controller can set its metadata.
    /// @dev Applications can use the domain namespace as they wish.
    /// @param _projectId The ID of the project who's metadata is being changed.
    /// @param _metadata A struct containing metadata content.
    function setMetadataOf(uint256 _projectId, string calldata _metadata)
        external
        override
        requirePermission(projects.ownerOf(_projectId), _projectId, JBOperations.SET_PROJECT_METADATA)
    {
        // Set the project's new metadata content within the specified domain.
        metadataOf[_projectId] = _metadata;

        emit SetMetadata(_projectId, _metadata, _msgSender());
    }

    /// @notice Sets a project's splits.
    /// @dev Only the owner or operator of a project, or the current controller contract of the project, can set its splits.
    /// @dev The new splits must include any currently set splits that are locked.
    /// @param _projectId The ID of the project for which splits are being added.
    /// @param _domain An identifier within which the splits should be considered active.
    /// @param _groupedSplits An array of splits to set for any number of groups.
    function setSplitsOf(
        uint256 _projectId,
        uint256 _domain,
        JBGroupedSplits[] calldata _groupedSplits
    )
        external
        virtual
        override
        requirePermission(projects.ownerOf(_projectId), _projectId, JBOperations.SET_SPLITS)
    {
        // Set splits for the group.
        splitsStore.set(_projectId, _domain, _groupedSplits);
    }

    /// @notice Issues a project's ERC-20 tokens that'll be used when claiming tokens.
    /// @dev Deploys a project's ERC-20 token contract.
    /// @dev Only a project's owner or operator can issue its token.
    /// @param _projectId The ID of the project being issued tokens.
    /// @param _name The ERC-20's name.
    /// @param _symbol The ERC-20's symbol.
    /// @return token The token that was issued.
    function issueTokenFor(uint256 _projectId, string calldata _name, string calldata _symbol)
        external
        virtual
        override
        requirePermission(projects.ownerOf(_projectId), _projectId, JBOperations.ISSUE_TOKEN)
        returns (IJBToken token)
    {
        return tokenStore.issueFor(_projectId, _name, _symbol);
    }

    /// @notice Set a project's token if not already set.
    /// @dev Only a project's owner or operator can set its token.
    /// @param _projectId The ID of the project to which the set token belongs.
    /// @param _token The new token.
    function setTokenFor(uint256 _projectId, IJBToken _token)
        external
        virtual
        override
        requirePermission(projects.ownerOf(_projectId), _projectId, JBOperations.SET_TOKEN)
    {
        tokenStore.setFor(_projectId, _token);
    }

    /// @notice Claims internally accounted for tokens into a holder's wallet.
    /// @dev Only a token holder or an operator specified by the token holder can claim its unclaimed tokens.
    /// @param _holder The owner of the tokens being claimed.
    /// @param _projectId The ID of the project whose tokens are being claimed.
    /// @param _amount The amount of tokens to claim.
    /// @param _beneficiary The account into which the claimed tokens will go.
    function claimFor(address _holder, uint256 _projectId, uint256 _amount, address _beneficiary)
        external
        virtual
        override
        requirePermission(_holder, _projectId, JBOperations.CLAIM_TOKENS)
    {
        tokenStore.claimFor(_holder, _projectId, _amount, _beneficiary);
    }

    /// @notice Allows a holder to transfer unclaimed tokens to another account.
    /// @dev Only a token holder or an operator can transfer its unclaimed tokens.
    /// @param _holder The address to transfer tokens from.
    /// @param _projectId The ID of the project whose tokens are being transferred.
    /// @param _recipient The recipient of the tokens.
    /// @param _amount The amount of tokens to transfer.
    function transferFrom(address _holder, uint256 _projectId, address _recipient, uint256 _amount)
        external
        virtual
        override
        requirePermission(_holder, _projectId, JBOperations.TRANSFER_TOKENS)
    {
        tokenStore.transferFrom(_holder, _projectId, _recipient, _amount);
    }

    //*********************************************************************//
    // ------------------------ internal functions ----------------------- //
    //*********************************************************************//

    /// @notice Distributes all outstanding reserved tokens for a project.
    /// @param _projectId The ID of the project to which the reserved tokens belong.
    /// @param _memo A memo to pass along to the emitted event.
    /// @return tokenCount The amount of minted reserved tokens.
    function _distributeReservedTokensOf(uint256 _projectId, string memory _memo)
        internal
        returns (uint256 tokenCount)
    {
        // Keep a reference to the token store.
        IJBTokenStore _tokenStore = tokenStore;

        // Get the current funding cycle to read the reserved rate from.
        JBFundingCycle memory _fundingCycle = fundingCycleStore.currentOf(_projectId);

        // Get a reference to the number of tokens that need to be minted.
        tokenCount = reservedTokenBalanceOf[_projectId];

        // Reset the reserved token balance
        reservedTokenBalanceOf[_projectId] = 0;

        // Get a reference to the project owner.
        address _owner = projects.ownerOf(_projectId);

        // Distribute tokens to splits and get a reference to the leftover amount to mint after all splits have gotten their share.
        uint256 _leftoverTokenCount = tokenCount == 0
            ? 0
            : _distributeToReservedTokenSplitsOf(
                _projectId, _fundingCycle.configuration, JBSplitsGroups.RESERVED_TOKENS, tokenCount
            );

        // Mint any leftover tokens to the project owner.
        if (_leftoverTokenCount > 0) _tokenStore.mintFor(_owner, _projectId, _leftoverTokenCount);

        emit DistributeReservedTokens(
            _fundingCycle.configuration,
            _fundingCycle.number,
            _projectId,
            _owner,
            tokenCount,
            _leftoverTokenCount,
            _memo,
            _msgSender()
        );
    }

    /// @notice Distribute tokens to the splits according to the specified funding cycle configuration.
    /// @param _projectId The ID of the project for which reserved token splits are being distributed.
    /// @param _domain The domain of the splits to distribute the reserved tokens between.
    /// @param _group The group of the splits to distribute the reserved tokens between.
    /// @param _amount The total amount of tokens to mint.
    /// @return leftoverAmount If the splits percents dont add up to 100%, the leftover amount is returned.
    function _distributeToReservedTokenSplitsOf(
        uint256 _projectId,
        uint256 _domain,
        uint256 _group,
        uint256 _amount
    ) internal returns (uint256 leftoverAmount) {
        // Keep a reference to the token store.
        IJBTokenStore _tokenStore = tokenStore;

        // Set the leftover amount to the initial amount.
        leftoverAmount = _amount;

        // Get a reference to the project's reserved token splits.
        JBSplit[] memory _splits = splitsStore.splitsOf(_projectId, _domain, _group);

        // Keep a reference to the number of splits being iterated on.
        uint256 _numberOfSplits = _splits.length;

        //Transfer between all splits.
        for (uint256 _i; _i < _numberOfSplits;) {
            // Get a reference to the split being iterated on.
            JBSplit memory _split = _splits[_i];

            // The amount to send towards the split.
            uint256 _tokenCount =
                PRBMath.mulDiv(_amount, _split.percent, JBConstants.SPLITS_TOTAL_PERCENT);

            // Mints tokens for the split if needed.
            if (_tokenCount > 0) {
                _tokenStore.mintFor(
                    // If an allocator is set in the splits, set it as the beneficiary.
                    // Otherwise if a projectId is set in the split, set the project's owner as the beneficiary.
                    // If the split has a beneficiary send to the split's beneficiary. Otherwise send to the  _msgSender().
                    _split.allocator != IJBSplitAllocator(address(0))
                        ? address(_split.allocator)
                        : _split.projectId != 0
                            ? projects.ownerOf(_split.projectId)
                            : _split.beneficiary != address(0) ? _split.beneficiary : _msgSender(),
                    _projectId,
                    _tokenCount
                );

                // If there's an allocator set, trigger its `allocate` function.
                if (_split.allocator != IJBSplitAllocator(address(0))) {
                    // Get a reference to the project's token.
                    address _token = address(_tokenStore.tokenOf(_projectId));

                    // Allocate.
                    _split.allocator.allocate(
                        JBSplitAllocationData(_token, _tokenCount, 18, _projectId, _group, _split)
                    );
                }

                // Subtract from the amount to be sent to the beneficiary.
                leftoverAmount = leftoverAmount - _tokenCount;
            }

            emit DistributeToReservedTokenSplit(
                _projectId, _domain, _group, _split, _tokenCount, _msgSender()
            );

            unchecked {
                ++_i;
            }
        }
    }

    /// @notice Configures a funding cycle and stores information pertinent to the configuration.
    /// @param _projectId The ID of the project whose funding cycles are being reconfigured.
    /// @param _fundingCycleConfigurations The funding cycle configurations to schedule.
    /// @return configured The configuration timestamp of the funding cycle that was successfully reconfigured.
    function _configureFundingCycles(
        uint256 _projectId,
        JBFundingCycleConfig[] calldata _fundingCycleConfigurations
    ) internal returns (uint256 configured) {
        // Keep a reference to the configuration being iterated on.
        JBFundingCycleConfig memory _configuration;

        // Keep a reference to the number of configurations being scheduled.
        uint256 _numberOfConfigurations = _fundingCycleConfigurations.length;

        for (uint256 _i; _i < _numberOfConfigurations;) {
            // Get a reference to the configuration being iterated on.
            _configuration = _fundingCycleConfigurations[_i];

            // Make sure the provided reserved rate is valid.
            if (_configuration.metadata.reservedRate > JBConstants.MAX_RESERVED_RATE) {
                revert INVALID_RESERVED_RATE();
            }

            // Make sure the provided redemption rate is valid.
            if (_configuration.metadata.redemptionRate > JBConstants.MAX_REDEMPTION_RATE) {
                revert INVALID_REDEMPTION_RATE();
            }

            // Make sure the provided base currency is valid.
            if (_configuration.metadata.baseCurrency > type(uint32).max) {
                revert INVALID_BASE_CURRENCY();
            }

            // Configure the funding cycle's properties.
            JBFundingCycle memory _fundingCycle = fundingCycleStore.configureFor(
                _projectId,
                _configuration.data,
                JBFundingCycleMetadataResolver.packFundingCycleMetadata(_configuration.metadata),
                _configuration.mustStartAtOrAfter
            );

            // Set splits for the group.
            splitsStore.set(_projectId, _fundingCycle.configuration, _configuration.groupedSplits);

            // Set the funds access constraints.
            fundAccessConstraintsStore.setFor(
                _projectId, _fundingCycle.configuration, _configuration.fundAccessConstraints
            );

            // Return the configured timestamp if this is the last configuration being scheduled.
            if (_i == _numberOfConfigurations - 1) configured = _fundingCycle.configuration;

            unchecked {
                ++_i;
            }
        }
    }

    /// @notice Configure terminals for use.
    /// @param _projectId The ID of the project configuring the terminals for use.
    /// @param _terminalConfigs The configurations to enact.
    function _configureTerminals(uint256 _projectId, JBTerminalConfig[] calldata _terminalConfigs)
        internal
    {
        // Keep a reference to the number of terminals being configured.
        uint256 _numberOfTerminalConfigs = _terminalConfigs.length;

        // Set a array of terminals to populate.
        IJBPaymentTerminal[] memory _terminals = new IJBPaymentTerminal[](_numberOfTerminalConfigs);

        // Keep a reference to the terminal configuration beingiterated on.
        JBTerminalConfig memory _terminalConfig;

        for (uint256 _i; _i < _numberOfTerminalConfigs;) {
            // Set the terminal configuration being iterated on.
            _terminalConfig = _terminalConfigs[_i];

            // Set the accounting contexts.
            _terminalConfig.terminal.setAccountingContextsFor(
                _projectId, _terminalConfig.accountingContextConfigs
            );

            // Add the terminal.
            _terminals[_i] = _terminalConfig.terminal;

            unchecked {
                ++_i;
            }
        }

        // Set the terminals in the directory.
        if (_numberOfTerminalConfigs > 0) directory.setTerminalsOf(_projectId, _terminals);
    }

    /// @notice Returns the sender, prefered to use over ` _msgSender()`
    /// @return _sender the sender address of this call.
    function _msgSender()
        internal
        view
        override(ERC2771Context, Context)
        returns (address _sender)
    {
        return ERC2771Context._msgSender();
    }

    /// @notice Returns the calldata, prefered to use over `msg.data`
    /// @return _calldata the `msg.data` of this call
    function _msgData()
        internal
        view
        override(ERC2771Context, Context)
        returns (bytes calldata _calldata)
    {
        return ERC2771Context._msgData();
    }
}
