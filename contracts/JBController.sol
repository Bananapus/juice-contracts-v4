// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {ERC165} from '@openzeppelin/contracts/utils/introspection/ERC165.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {PRBMath} from '@paulrberg/contracts/math/PRBMath.sol';
import {JBOperatable} from './abstract/JBOperatable.sol';
import {JBBallotState} from './enums/JBBallotState.sol';
import {IJBController} from './interfaces/IJBController.sol';
import {IJBDirectory} from './interfaces/IJBDirectory.sol';
import {IJBFundingCycleStore} from './interfaces/IJBFundingCycleStore.sol';
import {IJBMigratable} from './interfaces/IJBMigratable.sol';
import {IJBOperatable} from './interfaces/IJBOperatable.sol';
import {IJBOperatorStore} from './interfaces/IJBOperatorStore.sol';
import {IJBPaymentTerminal} from './interfaces/IJBPaymentTerminal.sol';
import {IJBProjects} from './interfaces/IJBProjects.sol';
import {IJBSplitAllocator} from './interfaces/IJBSplitAllocator.sol';
import {IJBSplitsStore} from './interfaces/IJBSplitsStore.sol';
import {IJBTokenStore} from './interfaces/IJBTokenStore.sol';
import {JBConstants} from './libraries/JBConstants.sol';
import {JBFundingCycleMetadataResolver} from './libraries/JBFundingCycleMetadataResolver.sol';
import {JBOperations} from './libraries/JBOperations.sol';
import {JBSplitsGroups} from './libraries/JBSplitsGroups.sol';
import {JBSplitAllocationData} from './structs/JBSplitAllocationData.sol';
import {JBFundAccessConstraints} from './structs/JBFundAccessConstraints.sol';
import {JBFundingCycle} from './structs/JBFundingCycle.sol';
import {JBFundingCycleData} from './structs/JBFundingCycleData.sol';
import {JBFundingCycleMetadata} from './structs/JBFundingCycleMetadata.sol';
import {JBGroupedSplits} from './structs/JBGroupedSplits.sol';
import {JBProjectMetadata} from './structs/JBProjectMetadata.sol';
import {JBSplit} from './structs/JBSplit.sol';

import {JBFundingCycleConfiguration} from './structs/JBFundingCycleConfiguration.sol';

/// @notice Stitches together funding cycles and project tokens, making sure all activity is accounted for and correct.
contract JBController is JBOperatable, ERC165, IJBController, IJBMigratable {
  // A library that parses the packed funding cycle metadata into a more friendly format.
  using JBFundingCycleMetadataResolver for JBFundingCycle;

  //*********************************************************************//
  // --------------------------- custom errors ------------------------- //
  //*********************************************************************//
  error BURN_PAUSED_AND_SENDER_NOT_VALID_TERMINAL_DELEGATE();
  error CANT_MIGRATE_TO_CURRENT_CONTROLLER();
  error FUNDING_CYCLE_ALREADY_LAUNCHED();
  error INVALID_BALLOT_REDEMPTION_RATE();
  error INVALID_DISTRIBUTION_LIMIT();
  error INVALID_DISTRIBUTION_LIMIT_CURRENCY();
  error INVALID_OVERFLOW_ALLOWANCE();
  error INVALID_OVERFLOW_ALLOWANCE_CURRENCY();
  error INVALID_REDEMPTION_RATE();
  error INVALID_RESERVED_RATE();
  error MIGRATION_NOT_ALLOWED();
  error MINT_NOT_ALLOWED_AND_NOT_TERMINAL_DELEGATE();
  error NO_BURNABLE_TOKENS();
  error NOT_CURRENT_CONTROLLER();
  error ZERO_TOKENS_TO_MINT();

  //*********************************************************************//
  // --------------------- internal stored properties ------------------ //
  //*********************************************************************//

  /// @notice The difference between the processed token tracker of a project and the project's token's total supply is the amount of tokens that still need to have reserves minted against them.
  /// @custom:param _projectId The ID of the project to get the tracker of.
  mapping(uint256 => int256) internal _processedTokenTrackerOf;

  /// @notice Data regarding the distribution limit of a project during a configuration.
  /// @dev bits 0-231: The amount of token that a project can distribute per funding cycle.
  /// @dev bits 232-255: The currency of amount that a project can distribute.
  /// @custom:param _projectId The ID of the project to get the packed distribution limit data of.
  /// @custom:param _configuration The configuration during which the packed distribution limit data applies.
  /// @custom:param _terminal The terminal from which distributions are being limited.
  /// @custom:param _token The token for which distributions are being limited.
  mapping(uint256 => mapping(uint256 => mapping(IJBPaymentTerminal => mapping(address => uint256))))
    internal _packedDistributionLimitDataOf;

  /// @notice Data regarding the overflow allowance of a project during a configuration.
  /// @dev bits 0-231: The amount of overflow that a project is allowed to tap into on-demand throughout the configuration.
  /// @dev bits 232-255: The currency of the amount of overflow that a project is allowed to tap.
  /// @custom:param _projectId The ID of the project to get the packed overflow allowance data of.
  /// @custom:param _configuration The configuration during which the packed overflow allowance data applies.
  /// @custom:param _terminal The terminal managing the overflow.
  /// @custom:param _token The token for which overflow is being allowed.
  mapping(uint256 => mapping(uint256 => mapping(IJBPaymentTerminal => mapping(address => uint256))))
    internal _packedOverflowAllowanceDataOf;

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

  /// @notice The directory of terminals and controllers for projects.
  IJBDirectory public immutable override directory;

  //*********************************************************************//
  // ------------------------- external views -------------------------- //
  //*********************************************************************//

  /// @notice The amount of token that a project can distribute per funding cycle, and the currency it's in terms of.
  /// @dev The number of decimals in the returned fixed point amount is the same as that of the specified terminal.
  /// @param _projectId The ID of the project to get the distribution limit of.
  /// @param _configuration The configuration during which the distribution limit applies.
  /// @param _terminal The terminal from which distributions are being limited.
  /// @param _token The token for which the distribution limit applies.
  /// @return The distribution limit, as a fixed point number with the same number of decimals as the provided terminal.
  /// @return The currency of the distribution limit.
  function distributionLimitOf(
    uint256 _projectId,
    uint256 _configuration,
    IJBPaymentTerminal _terminal,
    address _token
  ) external view override returns (uint256, uint256) {
    // Get a reference to the packed data.
    uint256 _data = _packedDistributionLimitDataOf[_projectId][_configuration][_terminal][_token];

    // The limit is in bits 0-231. The currency is in bits 232-255.
    return (uint256(uint232(_data)), _data >> 232);
  }

  /// @notice The amount of overflow that a project is allowed to tap into on-demand throughout a configuration, and the currency it's in terms of.
  /// @dev The number of decimals in the returned fixed point amount is the same as that of the specified terminal.
  /// @param _projectId The ID of the project to get the overflow allowance of.
  /// @param _configuration The configuration of the during which the allowance applies.
  /// @param _terminal The terminal managing the overflow.
  /// @param _token The token for which the overflow allowance applies.
  /// @return The overflow allowance, as a fixed point number with the same number of decimals as the provided terminal.
  /// @return The currency of the overflow allowance.
  function overflowAllowanceOf(
    uint256 _projectId,
    uint256 _configuration,
    IJBPaymentTerminal _terminal,
    address _token
  ) external view override returns (uint256, uint256) {
    // Get a reference to the packed data.
    uint256 _data = _packedOverflowAllowanceDataOf[_projectId][_configuration][_terminal][_token];

    // The allowance is in bits 0-231. The currency is in bits 232-255.
    return (uint256(uint232(_data)), _data >> 232);
  }

  /// @notice Gets the amount of reserved tokens that a project has available to distribute.
  /// @param _projectId The ID of the project to get a reserved token balance of.
  /// @param _reservedRate The reserved rate to use when making the calculation.
  /// @return The current amount of reserved tokens.
  function reservedTokenBalanceOf(uint256 _projectId, uint256 _reservedRate)
    external
    view
    override
    returns (uint256)
  {
    return
      _reservedTokenAmountFrom(
        _processedTokenTrackerOf[_projectId],
        _reservedRate,
        tokenStore.totalSupplyOf(_projectId)
      );
  }

  /// @notice Gets the current total amount of outstanding tokens for a project, given a reserved rate.
  /// @param _projectId The ID of the project to get total outstanding tokens of.
  /// @param _reservedRate The reserved rate to use when making the calculation.
  /// @return The current total amount of outstanding tokens for the project.
  function totalOutstandingTokensOf(uint256 _projectId, uint256 _reservedRate)
    external
    view
    override
    returns (uint256)
  {
    // Get the total number of tokens in circulation.
    uint256 _totalSupply = tokenStore.totalSupplyOf(_projectId);

    // Get the number of reserved tokens the project has.
    uint256 _reservedTokenAmount = _reservedTokenAmountFrom(
      _processedTokenTrackerOf[_projectId],
      _reservedRate,
      _totalSupply
    );

    // Add the reserved tokens to the total supply.
    return _totalSupply + _reservedTokenAmount;
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
    return
      _interfaceId == type(IJBController).interfaceId ||
      _interfaceId == type(IJBMigratable).interfaceId ||
      _interfaceId == type(IJBOperatable).interfaceId ||
      super.supportsInterface(_interfaceId);
  }

  //*********************************************************************//
  // ---------------------------- constructor -------------------------- //
  //*********************************************************************//

  /// @param _operatorStore A contract storing operator assignments.
  /// @param _projects A contract which mints ERC-721's that represent project ownership and transfers.
  /// @param _directory A contract storing directories of terminals and controllers for each project.
  /// @param _fundingCycleStore A contract storing all funding cycle configurations.
  /// @param _tokenStore A contract that manages token minting and burning.
  /// @param _splitsStore A contract that stores splits for each project.
  constructor(
    IJBOperatorStore _operatorStore,
    IJBProjects _projects,
    IJBDirectory _directory,
    IJBFundingCycleStore _fundingCycleStore,
    IJBTokenStore _tokenStore,
    IJBSplitsStore _splitsStore
  ) JBOperatable(_operatorStore) {
    projects = _projects;
    directory = _directory;
    fundingCycleStore = _fundingCycleStore;
    tokenStore = _tokenStore;
    splitsStore = _splitsStore;
  }

  //*********************************************************************//
  // --------------------- external transactions ----------------------- //
  //*********************************************************************//

  /// @notice Creates a project. This will mint an ERC-721 into the specified owner's account, configure a first funding cycle, and set up any splits.
  /// @dev Each operation within this transaction can be done in sequence separately.
  /// @dev Anyone can deploy a project on an owner's behalf.
  /// @param _owner The address to set as the owner of the project. The project ERC-721 will be owned by this address.
  /// @param _projectMetadata Metadata to associate with the project within a particular domain. This can be updated any time by the owner of the project.
  /// @param _configurations The funding cycle configurations to schedule.
  /// @param _terminals Payment terminals to add for the project.
  /// @param _memo A memo to pass along to the emitted event.
  /// @return projectId The ID of the project.
  function launchProjectFor(
    address _owner,
    JBProjectMetadata calldata _projectMetadata,
    JBFundingCycleConfiguration[] calldata _configurations,
    IJBPaymentTerminal[] memory _terminals,
    string memory _memo
  ) external virtual override returns (uint256 projectId) {
    // Keep a reference to the directory.
    IJBDirectory _directory = directory;

    // Mint the project into the wallet of the owner.
    projectId = projects.createFor(_owner, _projectMetadata);

    // Set this contract as the project's controller in the directory.
    _directory.setControllerOf(projectId, address(this));

    // Configure the first funding cycle.
    uint256 _configuration = _configure(projectId, _configurations);

    // Add the provided terminals to the list of terminals.
    if (_terminals.length > 0) _directory.setTerminalsOf(projectId, _terminals);

    emit LaunchProject(_configuration, projectId, _memo, msg.sender);
  }

  /// @notice Proposes a configuration of a subsequent funding cycle that will take effect once the current one expires if it is approved by the current funding cycle's ballot.
  /// @dev Only a project's owner or a designated operator can configure its funding cycles.
  /// @param _projectId The ID of the project whose funding cycles are being reconfigured.
  /// @param _configurations The funding cycle configurations to schedule.
  /// @param _memo A memo to pass along to the emitted event.
  /// @return configured The configuration timestamp of the funding cycle that was successfully reconfigured.
  function reconfigureFundingCyclesOf(
    uint256 _projectId,
    JBFundingCycleConfiguration[] calldata _configurations,
    string calldata _memo
  )
    external
    virtual
    override
    requirePermission(projects.ownerOf(_projectId), _projectId, JBOperations.RECONFIGURE)
    returns (uint256 configured)
  {
    // Configure the next funding cycle.
    configured = _configure(_projectId, _configurations);

    emit ReconfigureFundingCycles(configured, _projectId, _memo, msg.sender);
  }

  /// @notice Mint new token supply into an account, and optionally reserve a supply to be distributed according to the project's current funding cycle configuration.
  /// @dev Only a project's owner, a designated operator, one of its terminals, or the current data source can mint its tokens.
  /// @param _projectId The ID of the project to which the tokens being minted belong.
  /// @param _tokenCount The amount of tokens to mint in total, counting however many should be reserved.
  /// @param _beneficiary The account that the tokens are being minted for.
  /// @param _memo A memo to pass along to the emitted event.
  /// @param _preferClaimedTokens A flag indicating whether a project's attached token contract should be minted if they have been issued.
  /// @param _useReservedRate Whether to use the current funding cycle's reserved rate in the mint calculation.
  /// @return beneficiaryTokenCount The amount of tokens minted for the beneficiary.
  function mintTokensOf(
    uint256 _projectId,
    uint256 _tokenCount,
    address _beneficiary,
    string calldata _memo,
    bool _preferClaimedTokens,
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
        JBOperations.MINT,
        directory.isTerminalOf(_projectId, IJBPaymentTerminal(msg.sender)) ||
          msg.sender == address(_fundingCycle.dataSource())
      );

      // If the message sender is not a terminal or a datasource, the current funding cycle must allow minting.
      if (
        !_fundingCycle.mintingAllowed() &&
        !directory.isTerminalOf(_projectId, IJBPaymentTerminal(msg.sender)) &&
        msg.sender != address(_fundingCycle.dataSource())
      ) revert MINT_NOT_ALLOWED_AND_NOT_TERMINAL_DELEGATE();

      // Determine the reserved rate to use.
      _reservedRate = _useReservedRate ? _fundingCycle.reservedRate() : 0;

      // Override the claimed token preference with the funding cycle value.
      _preferClaimedTokens = _preferClaimedTokens == true
        ? _preferClaimedTokens
        : _fundingCycle.preferClaimedTokenOverride();
    }

    if (_reservedRate == JBConstants.MAX_RESERVED_RATE)
      // Subtract the total weighted amount from the tracker so the full reserved token amount can be printed later.
      _processedTokenTrackerOf[_projectId] =
        _processedTokenTrackerOf[_projectId] -
        SafeCast.toInt256(_tokenCount);
    else {
      // The unreserved token count that will be minted for the beneficiary.
      beneficiaryTokenCount = PRBMath.mulDiv(
        _tokenCount,
        JBConstants.MAX_RESERVED_RATE - _reservedRate,
        JBConstants.MAX_RESERVED_RATE
      );

      if (_reservedRate == 0)
        // If there's no reserved rate, increment the tracker with the newly minted tokens.
        _processedTokenTrackerOf[_projectId] =
          _processedTokenTrackerOf[_projectId] +
          SafeCast.toInt256(beneficiaryTokenCount);

      // Mint the tokens.
      tokenStore.mintFor(_beneficiary, _projectId, beneficiaryTokenCount, _preferClaimedTokens);
    }

    emit MintTokens(
      _beneficiary,
      _projectId,
      _tokenCount,
      beneficiaryTokenCount,
      _memo,
      _reservedRate,
      msg.sender
    );
  }

  /// @notice Burns a token holder's supply.
  /// @dev Only a token's holder, a designated operator, or a project's terminal can burn it.
  /// @param _holder The account that is having its tokens burned.
  /// @param _projectId The ID of the project to which the tokens being burned belong.
  /// @param _tokenCount The number of tokens to burn.
  /// @param _memo A memo to pass along to the emitted event.
  /// @param _preferClaimedTokens A flag indicating whether a project's attached token contract should be burned first if they have been issued.
  function burnTokensOf(
    address _holder,
    uint256 _projectId,
    uint256 _tokenCount,
    string calldata _memo,
    bool _preferClaimedTokens
  )
    external
    virtual
    override
    requirePermissionAllowingOverride(
      _holder,
      _projectId,
      JBOperations.BURN,
      directory.isTerminalOf(_projectId, IJBPaymentTerminal(msg.sender))
    )
  {
    // There should be tokens to burn
    if (_tokenCount == 0) revert NO_BURNABLE_TOKENS();

    // Get a reference to the project's current funding cycle.
    JBFundingCycle memory _fundingCycle = fundingCycleStore.currentOf(_projectId);

    // If the message sender is a terminal, the current funding cycle must not be paused.
    if (
      _fundingCycle.burnPaused() &&
      !directory.isTerminalOf(_projectId, IJBPaymentTerminal(msg.sender))
    ) revert BURN_PAUSED_AND_SENDER_NOT_VALID_TERMINAL_DELEGATE();

    // Update the token tracker so that reserved tokens will still be correctly mintable.
    _processedTokenTrackerOf[_projectId] =
      _processedTokenTrackerOf[_projectId] -
      SafeCast.toInt256(_tokenCount);

    // Burn the tokens.
    tokenStore.burnFrom(_holder, _projectId, _tokenCount, _preferClaimedTokens);

    emit BurnTokens(_holder, _projectId, _tokenCount, _memo, msg.sender);
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
  /// @param _projectId The ID of the project that will be migrated to this controller.
  /// @param _from The controller being migrated from.
  function prepForMigrationOf(uint256 _projectId, address _from) external virtual override {
    // This controller must not be the project's current controller.
    if (directory.controllerOf(_projectId) == address(this))
      revert CANT_MIGRATE_TO_CURRENT_CONTROLLER();

    // Set the tracker as the total supply.
    _processedTokenTrackerOf[_projectId] = SafeCast.toInt256(tokenStore.totalSupplyOf(_projectId));

    emit PrepMigration(_projectId, _from, msg.sender);
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

    // This controller must be the project's current controller.
    if (_directory.controllerOf(_projectId) != address(this)) revert NOT_CURRENT_CONTROLLER();

    // Get a reference to the project's current funding cycle.
    JBFundingCycle memory _fundingCycle = fundingCycleStore.currentOf(_projectId);

    // Migration must be allowed.
    if (!_fundingCycle.controllerMigrationAllowed()) revert MIGRATION_NOT_ALLOWED();

    // All reserved tokens must be minted before migrating.
    if (
      _processedTokenTrackerOf[_projectId] < 0 ||
      uint256(_processedTokenTrackerOf[_projectId]) != tokenStore.totalSupplyOf(_projectId)
    ) _distributeReservedTokensOf(_projectId, '');

    // Make sure the new controller is prepped for the migration.
    _to.prepForMigrationOf(_projectId, address(this));

    // Set the new controller.
    _directory.setControllerOf(_projectId, address(_to));

    emit Migrate(_projectId, _to, msg.sender);
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

    // Get a reference to new total supply of tokens before minting reserved tokens.
    uint256 _totalTokens = _tokenStore.totalSupplyOf(_projectId);

    // Get a reference to the number of tokens that need to be minted.
    tokenCount = _reservedTokenAmountFrom(
      _processedTokenTrackerOf[_projectId],
      _fundingCycle.reservedRate(),
      _totalTokens
    );

    // Set the tracker to be the new total supply.
    _processedTokenTrackerOf[_projectId] = SafeCast.toInt256(_totalTokens + tokenCount);

    // Get a reference to the project owner.
    address _owner = projects.ownerOf(_projectId);

    // Distribute tokens to splits and get a reference to the leftover amount to mint after all splits have gotten their share.
    uint256 _leftoverTokenCount = tokenCount == 0
      ? 0
      : _distributeToReservedTokenSplitsOf(
        _projectId,
        _fundingCycle.configuration,
        JBSplitsGroups.RESERVED_TOKENS,
        tokenCount
      );

    // Mint any leftover tokens to the project owner.
    if (_leftoverTokenCount > 0)
      _tokenStore.mintFor(_owner, _projectId, _leftoverTokenCount, false);

    emit DistributeReservedTokens(
      _fundingCycle.configuration,
      _fundingCycle.number,
      _projectId,
      _owner,
      tokenCount,
      _leftoverTokenCount,
      _memo,
      msg.sender
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

    //Transfer between all splits.
    for (uint256 _i; _i < _splits.length; ) {
      // Get a reference to the split being iterated on.
      JBSplit memory _split = _splits[_i];

      // The amount to send towards the split.
      uint256 _tokenCount = PRBMath.mulDiv(
        _amount,
        _split.percent,
        JBConstants.SPLITS_TOTAL_PERCENT
      );

      // Mints tokens for the split if needed.
      if (_tokenCount > 0) {
        _tokenStore.mintFor(
          // If an allocator is set in the splits, set it as the beneficiary.
          // Otherwise if a projectId is set in the split, set the project's owner as the beneficiary.
          // If the split has a beneficiary send to the split's beneficiary. Otherwise send to the msg.sender.
          _split.allocator != IJBSplitAllocator(address(0))
            ? address(_split.allocator)
            : _split.projectId != 0
            ? projects.ownerOf(_split.projectId)
            : _split.beneficiary != address(0)
            ? _split.beneficiary
            : msg.sender,
          _projectId,
          _tokenCount,
          _split.preferClaimed
        );

        // If there's an allocator set, trigger its `allocate` function.
        if (_split.allocator != IJBSplitAllocator(address(0)))
          _split.allocator.allocate(
            JBSplitAllocationData(
              address(_tokenStore.tokenOf(_projectId)),
              _tokenCount,
              18,
              _projectId,
              _group,
              _split
            )
          );

        // Subtract from the amount to be sent to the beneficiary.
        leftoverAmount = leftoverAmount - _tokenCount;
      }

      emit DistributeToReservedTokenSplit(
        _projectId,
        _domain,
        _group,
        _split,
        _tokenCount,
        msg.sender
      );

      unchecked {
        ++_i;
      }
    }
  }

  /// @notice Configures a funding cycle and stores information pertinent to the configuration.
  /// @param _projectId The ID of the project whose funding cycles are being reconfigured.
  /// @param _configurations The funding cycle configurations to schedule.
  /// @return configured The configuration timestamp of the funding cycle that was successfully reconfigured.
  function _configure(uint256 _projectId, JBFundingCycleConfiguration[] calldata _configurations)
    internal
    returns (uint256 configured)
  {
    // Keep a reference to the configuration being iterated on.
    JBFundingCycleConfiguration memory _configuration;

    // Keep a reference to the number of configurations being scheduled.
    uint256 _numberOfConfigurations = _configurations.length;

    for (uint256 _i; _i < _numberOfConfigurations; ) {
      // Get a reference to the configuration being iterated on.
      _configuration = _configurations[_i];

      // Make sure the provided reserved rate is valid.
      if (_configuration.metadata.reservedRate > JBConstants.MAX_RESERVED_RATE)
        revert INVALID_RESERVED_RATE();

      // Make sure the provided redemption rate is valid.
      if (_configuration.metadata.redemptionRate > JBConstants.MAX_REDEMPTION_RATE)
        revert INVALID_REDEMPTION_RATE();

      // Make sure the provided ballot redemption rate is valid.
      if (_configuration.metadata.ballotRedemptionRate > JBConstants.MAX_REDEMPTION_RATE)
        revert INVALID_BALLOT_REDEMPTION_RATE();

      // Configure the funding cycle's properties.
      JBFundingCycle memory _fundingCycle = fundingCycleStore.configureFor(
        _projectId,
        _configuration.data,
        JBFundingCycleMetadataResolver.packFundingCycleMetadata(_configuration.metadata),
        _configuration.mustStartAtOrAfter
      );

      // Set splits for the group.
      splitsStore.set(_projectId, _fundingCycle.configuration, _configuration.groupedSplits);

      // Set distribution limits if there are any.
      for (uint256 i_; i_ < _configuration.fundAccessConstraints.length; ) {
        JBFundAccessConstraints memory _constraints = _configuration.fundAccessConstraints[i_];

        // If distribution limit value is larger than 232 bits, revert.
        if (_constraints.distributionLimit > type(uint232).max) revert INVALID_DISTRIBUTION_LIMIT();

        // If distribution limit currency value is larger than 24 bits, revert.
        if (_constraints.distributionLimitCurrency > type(uint24).max)
          revert INVALID_DISTRIBUTION_LIMIT_CURRENCY();

        // If overflow allowance value is larger than 232 bits, revert.
        if (_constraints.overflowAllowance > type(uint232).max) revert INVALID_OVERFLOW_ALLOWANCE();

        // If overflow allowance currency value is larger than 24 bits, revert.
        if (_constraints.overflowAllowanceCurrency > type(uint24).max)
          revert INVALID_OVERFLOW_ALLOWANCE_CURRENCY();

        // Set the distribution limit if there is one.
        if (_constraints.distributionLimit > 0)
          _packedDistributionLimitDataOf[_projectId][_fundingCycle.configuration][
            _constraints.terminal
          ][_constraints.token] =
            _constraints.distributionLimit |
            (_constraints.distributionLimitCurrency << 232);

        // Set the overflow allowance if there is one.
        if (_constraints.overflowAllowance > 0)
          _packedOverflowAllowanceDataOf[_projectId][_fundingCycle.configuration][
            _constraints.terminal
          ][_constraints.token] =
            _constraints.overflowAllowance |
            (_constraints.overflowAllowanceCurrency << 232);

        emit SetFundAccessConstraints(
          _fundingCycle.configuration,
          _fundingCycle.number,
          _projectId,
          _constraints,
          msg.sender
        );

        unchecked {
          ++i_;
        }
      }

      /* // Set the funds access constraints.
      fundAccessConstraintsStore.setFor(
        _projectId,
        _fundingCycle.configuration,
        _configuration.fundAccessConstraints
      ); */

      // Return the configured timestamp if this is the last configuration being scheduled.
      if (_i == _numberOfConfigurations - 1) configured = _fundingCycle.configuration;

      unchecked {
        ++_i;
      }
    }
  }

  /// @notice Gets the amount of reserved tokens currently tracked for a project given a reserved rate.
  /// @param _processedTokenTracker The tracker to make the calculation with.
  /// @param _reservedRate The reserved rate to use to make the calculation.
  /// @param _totalEligibleTokens The total amount to make the calculation with.
  /// @return amount reserved token amount.
  function _reservedTokenAmountFrom(
    int256 _processedTokenTracker,
    uint256 _reservedRate,
    uint256 _totalEligibleTokens
  ) internal pure returns (uint256) {
    // Get a reference to the amount of tokens that are unprocessed.
    uint256 _unprocessedTokenBalanceOf = _processedTokenTracker >= 0
      ? _totalEligibleTokens - uint256(_processedTokenTracker)
      : _totalEligibleTokens + uint256(-_processedTokenTracker);

    // If there are no unprocessed tokens, return.
    if (_unprocessedTokenBalanceOf == 0) return 0;

    // If all tokens are reserved, return the full unprocessed amount.
    if (_reservedRate == JBConstants.MAX_RESERVED_RATE) return _unprocessedTokenBalanceOf;

    return
      PRBMath.mulDiv(
        _unprocessedTokenBalanceOf,
        JBConstants.MAX_RESERVED_RATE,
        JBConstants.MAX_RESERVED_RATE - _reservedRate
      ) - _unprocessedTokenBalanceOf;
  }
}
