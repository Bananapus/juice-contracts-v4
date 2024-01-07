// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Context} from "lib/openzeppelin-contracts/contracts/utils/Context.sol";
import {ERC165} from "lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {ERC2771Context} from "lib/openzeppelin-contracts/contracts/metatx/ERC2771Context.sol";
import {mulDiv} from "lib/prb-math/src/Common.sol";
import {JBPermissioned} from "./abstract/JBPermissioned.sol";
import {JBApprovalStatus} from "./enums/JBApprovalStatus.sol";
import {IJBController} from "./interfaces/IJBController.sol";
import {IJBDirectory} from "./interfaces/IJBDirectory.sol";
import {IJBFundAccessLimits} from "./interfaces/IJBFundAccessLimits.sol";
import {IJBRulesets} from "./interfaces/IJBRulesets.sol";
import {IJBDirectoryAccessControl} from "./interfaces/IJBDirectoryAccessControl.sol";
import {IJBMigratable} from "./interfaces/IJBMigratable.sol";
import {IJBPermissioned} from "./interfaces/IJBPermissioned.sol";
import {IJBRulesetDataHook} from "./interfaces/IJBRulesetDataHook.sol";
import {IJBPermissions} from "./interfaces/IJBPermissions.sol";
import {IJBTerminal} from "./interfaces/terminal/IJBTerminal.sol";
import {IJBProjects} from "./interfaces/IJBProjects.sol";
import {IJBProjectMetadataRegistry} from "./interfaces/IJBProjectMetadataRegistry.sol";
import {IJBSplitHook} from "./interfaces/IJBSplitHook.sol";
import {IJBSplits} from "./interfaces/IJBSplits.sol";
import {IJBToken} from "./interfaces/IJBToken.sol";
import {IJBTokens} from "./interfaces/IJBTokens.sol";
import {JBConstants} from "./libraries/JBConstants.sol";
import {JBRulesetMetadataResolver} from "./libraries/JBRulesetMetadataResolver.sol";
import {JBPermissionIds} from "./libraries/JBPermissionIds.sol";
import {JBSplitGroupIds} from "./libraries/JBSplitGroupIds.sol";
import {JBRuleset} from "./structs/JBRuleset.sol";
import {JBRulesetWithMetadata} from "./structs/JBRulesetWithMetadata.sol";
import {JBRulesetConfig} from "./structs/JBRulesetConfig.sol";
import {JBRulesetMetadata} from "./structs/JBRulesetMetadata.sol";
import {JBTerminalConfig} from "./structs/JBTerminalConfig.sol";
import {JBSplit} from "./structs/JBSplit.sol";
import {JBSplitGroup} from "./structs/JBSplitGroup.sol";
import {JBSplitHookContext} from "./structs/JBSplitHookContext.sol";

/// @notice Stitches together rulesets and project tokens, making sure all activity is accounted for and correct.
contract JBController is JBPermissioned, ERC2771Context, ERC165, IJBController, IJBMigratable {
    // A library that parses packed ruleset metadata into a friendlier format.
    using JBRulesetMetadataResolver for JBRuleset;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error RULESET_ALREADY_LAUNCHED();
    error INVALID_BASE_CURRENCY();
    error INVALID_REDEMPTION_RATE();
    error INVALID_RESERVED_RATE();
    error CONTROLLER_MIGRATION_NOT_ALLOWED();
    error MINT_NOT_ALLOWED_AND_NOT_TERMINAL_OR_HOOK();
    error NO_BURNABLE_TOKENS();
    error CREDIT_TRANSFERS_PAUSED();
    error ZERO_TOKENS_TO_MINT();

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice Mints ERC-721s that represent project ownership and transfers.
    IJBProjects public immutable override PROJECTS;

    /// @notice The directory of terminals and controllers for projects.
    IJBDirectory public immutable override DIRECTORY;

    /// @notice The contract storing and managing project rulesets.
    IJBRulesets public immutable override RULESETS;

    /// @notice The contract that manages token minting and burning.
    IJBTokens public immutable override TOKENS;

    /// @notice The contract that stores splits for each project.
    IJBSplits public immutable override SPLITS;

    /// @notice A contract that stores fund access limits for each project.
    IJBFundAccessLimits public immutable override FUND_ACCESS_LIMITS;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice The reserved token balance that has not yet been realized (sent out to the reserved split group) for a
    /// project.
    /// @custom:param projectId The ID of the project to get the pending reserved token balance of.
    mapping(uint256 projectId => uint256) public override pendingReservedTokenBalanceOf;

    /// @notice The metadata for each project.
    /// @custom:param projectId The ID of the project to which the metadata belongs.
    mapping(uint256 projectId => string) public override metadataOf;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Gets the current token supply of a project, including pending reserved tokens.
    /// @param projectId The ID of the project to get the total token supply of.
    /// @return The current total token supply of the project, including pending reserved tokens that have not been sent
    /// to splits yet.
    function totalTokenSupplyWithReservedTokensOf(uint256 projectId) external view override returns (uint256) {
        // Add the reserved tokens to the total supply.
        return TOKENS.totalSupplyOf(projectId) + pendingReservedTokenBalanceOf[projectId];
    }

    /// @notice A get `JBRuleset` and `JBRulesetMetadata` structs for the specified `rulesetId`.
    /// @param projectId The ID of the project the ruleset belongs to.
    /// @return ruleset The ruleset as a `JBRuleset` struct.
    /// @return metadata The ruleset's metadata as a `JBRulesetMetadata` struct.
    function getRulesetOf(
        uint256 projectId,
        uint256 rulesetId
    )
        external
        view
        override
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        ruleset = RULESETS.getRulesetOf(projectId, rulesetId);
        metadata = ruleset.expandMetadata();
    }

    /// @notice The latest ruleset queued for a project. Returns the ruleset's struct, its current approval status, and
    /// its metadata.
    /// @param projectId The ID of the project the ruleset belongs to.
    /// @return ruleset The latest queued ruleset as a `JBRuleset` struct.
    /// @return metadata The latest queued ruleset's metadata as a `JBRulesetMetadata` struct.
    /// @return approvalStatus The approval status of the ruleset.
    function latestQueuedRulesetOf(uint256 projectId)
        external
        view
        override
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata, JBApprovalStatus approvalStatus)
    {
        (ruleset, approvalStatus) = RULESETS.latestQueuedRulesetOf(projectId);
        metadata = ruleset.expandMetadata();
    }

    /// @notice Get all the currently queued rulesets for a project, including their metadata.
    /// @param projectId The ID of the project to get the queued rulesets of.
    /// @return queuedRulesets The queued rulesets as an array of `JBRulesetWithMetadata` structs.
    function queuedRulesetsOf(uint256 projectId)
        external
        view
        override
        returns (JBRulesetWithMetadata[] memory queuedRulesets)
    {
        // Get the queued rulesets.
        JBRuleset[] memory rulesets = RULESETS.queuedRulesetsOf(projectId);

        // Keep a reference to the number of rulesets.
        uint256 numberOfRulesets = rulesets.length;

        // Initialize the array being returned.
        queuedRulesets = new JBRulesetWithMetadata[](numberOfRulesets);

        // Keep a reference to the ruleset being iterated on.
        JBRuleset memory ruleset;

        // Populate the array with the rulesets and their metadata.
        for (uint256 i; i < numberOfRulesets; i++) {
            // Set the ruleset being iterated on.
            ruleset = rulesets[i];

            // Set the returned value.
            queuedRulesets[i] = JBRulesetWithMetadata({ruleset: ruleset, metadata: ruleset.expandMetadata()});
        }
    }

    /// @notice A project's current ruleset along with its metadata.
    /// @param projectId The ID of the project the ruleset belongs to.
    /// @return ruleset The current ruleset as a `JBRuleset` struct.
    /// @return metadata The current ruleset's metadata as a `JBRulesetMetadata` struct.
    function currentRulesetOf(uint256 projectId)
        external
        view
        override
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        ruleset = RULESETS.currentOf(projectId);
        metadata = ruleset.expandMetadata();
    }

    /// @notice A project's upcoming ruleset along with its metadata.
    /// @dev If an upcoming ruleset is not found for the project, returns an empty ruleset with all properties set to 0.
    /// @param projectId The ID of the project the ruleset belongs to.
    /// @return ruleset The upcoming ruleset as a `JBRuleset` struct.
    /// @return metadata The upcoming ruleset's metadata as a `JBRulesetMetadata` struct.
    function upcomingRulesetOf(uint256 projectId)
        external
        view
        override
        returns (JBRuleset memory ruleset, JBRulesetMetadata memory metadata)
    {
        ruleset = RULESETS.upcomingRulesetOf(projectId);
        metadata = ruleset.expandMetadata();
    }

    /// @notice A flag indicating if the project currently allows terminals to be set.
    /// @param projectId The ID of the project the flag is for.
    /// @return The flag
    function setTerminalsAllowed(uint256 projectId) external view returns (bool) {
        return RULESETS.currentOf(projectId).expandMetadata().allowSetTerminals;
    }

    /// @notice A flag indicating if the project currently allows its controller to be set.
    /// @param projectId The ID of the project the flag is for.
    /// @return The flag
    function setControllerAllowed(uint256 projectId) external view returns (bool) {
        return RULESETS.currentOf(projectId).expandMetadata().allowSetController;
    }

    //*********************************************************************//
    // -------------------------- public views --------------------------- //
    //*********************************************************************//

    /// @notice Indicates if this contract adheres to the specified interface.
    /// @dev See {IERC165-supportsInterface}.
    /// @param interfaceId The ID of the interface to check for adherance to.
    /// @return A flag indicating if the provided interface ID is supported.
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IJBController).interfaceId
            || interfaceId == type(IJBProjectMetadataRegistry).interfaceId
            || interfaceId == type(IJBDirectoryAccessControl).interfaceId || interfaceId == type(IJBMigratable).interfaceId
            || interfaceId == type(IJBPermissioned).interfaceId || super.supportsInterface(interfaceId);
    }

    //*********************************************************************//
    // ---------------------------- constructor -------------------------- //
    //*********************************************************************//

    /// @param permissions A contract storing permissions.
    /// @param projects A contract which mints ERC-721s that represent project ownership and transfers.
    /// @param directory A contract storing directories of terminals and controllers for each project.
    /// @param rulesets A contract storing and managing project rulesets.
    /// @param tokens A contract that manages token minting and burning.
    /// @param splits A contract that stores splits for each project.
    /// @param fundAccessLimits A contract that stores fund access limits for each project.
    constructor(
        IJBPermissions permissions,
        IJBProjects projects,
        IJBDirectory directory,
        IJBRulesets rulesets,
        IJBTokens tokens,
        IJBSplits splits,
        IJBFundAccessLimits fundAccessLimits,
        address trustedForwarder
    )
        JBPermissioned(permissions)
        ERC2771Context(trustedForwarder)
    {
        PROJECTS = projects;
        DIRECTORY = directory;
        RULESETS = rulesets;
        TOKENS = tokens;
        SPLITS = splits;
        FUND_ACCESS_LIMITS = fundAccessLimits;
    }

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Creates a project. This will mint the project's ERC-721 to the specified owner's account, queue its
    /// first ruleset, and set up any splits.
    /// @dev Each operation within this transaction can be done in sequence separately.
    /// @dev Anyone can deploy a project on an owner's behalf.
    /// @param owner The address to set as the owner of the project. The project ERC-721 will be owned by this address.
    /// @param projectMetadata Metadata to associate with the project. This can be updated any time by the owner of the
    /// project.
    /// @param rulesetConfigurations The ruleset configurations to queue.
    /// @param terminalConfigurations The terminal configurations to add for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @return projectId The ID of the project.
    function launchProjectFor(
        address owner,
        string calldata projectMetadata,
        JBRulesetConfig[] calldata rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string memory memo
    )
        external
        virtual
        override
        returns (uint256 projectId)
    {
        // Mint the project into the wallet of the owner.
        projectId = PROJECTS.createFor(owner);

        // Set project metadata if one was provided.
        if (bytes(projectMetadata).length > 0) {
            metadataOf[projectId] = projectMetadata;
        }

        // Set this contract as the project's controller in the directory.
        DIRECTORY.setControllerOf(projectId, IERC165(this));

        // Queue the first ruleset.
        uint256 rulesetId = _queueRulesets(projectId, rulesetConfigurations);

        // Configure the terminals.
        _configureTerminals(projectId, terminalConfigurations);

        emit LaunchProject(rulesetId, projectId, projectMetadata, memo, _msgSender());
    }

    /// @notice Creates an initial sequence of one or more rulesets for an existing project.
    /// @dev Each operation within this transaction can be done in sequence separately.
    /// @dev Only a project's owner or an operator with the `QUEUE_RULESETS` permission can launch rulesets for a
    /// project.
    /// @param projectId The ID of the project to launch rulesets for.
    /// @param rulesetConfigurations The ruleset configurations to queue.
    /// @param terminalConfigurations The terminal configurations to add for the project.
    /// @param memo A memo to pass along to the emitted event.
    /// @return rulesetId The ID of the ruleset that was successfully launched.
    function launchRulesetsFor(
        uint256 projectId,
        JBRulesetConfig[] calldata rulesetConfigurations,
        JBTerminalConfig[] calldata terminalConfigurations,
        string memory memo
    )
        external
        virtual
        override
        returns (uint256 rulesetId)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.QUEUE_RULESETS
        });

        // If the project has already had rulesets, `queueRulesetsOf(...)` should be called instead
        if (RULESETS.latestRulesetIdOf(projectId) > 0) {
            revert RULESET_ALREADY_LAUNCHED();
        }

        // Set this contract as the project's controller in the directory.
        DIRECTORY.setControllerOf(projectId, IERC165(this));

        // Queue the first ruleset.
        rulesetId = _queueRulesets(projectId, rulesetConfigurations);

        // Configure the terminals.
        _configureTerminals(projectId, terminalConfigurations);

        emit LaunchRulesets(rulesetId, projectId, memo, _msgSender());
    }

    /// @notice Queues one or more rulesets that will take effect once the current ruleset expires. Rulesets only take
    /// effect if they are approved by the previous ruleset's approval hook.
    /// @dev Only a project's owner or an operator with the `QUEUE_RULESETS` permission from them can queue rulesets for
    /// a project.
    /// @param projectId The ID of the project that rulesets are being queued for.
    /// @param rulesetConfigurations The configurations of the rulesets to queue.
    /// @param memo A memo to pass along to the emitted event.
    /// @return rulesetId The ID of the last ruleset which was successfully queued.
    function queueRulesetsOf(
        uint256 projectId,
        JBRulesetConfig[] calldata rulesetConfigurations,
        string calldata memo
    )
        external
        virtual
        override
        returns (uint256 rulesetId)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.QUEUE_RULESETS
        });

        // Queue the next ruleset.
        rulesetId = _queueRulesets(projectId, rulesetConfigurations);

        emit QueueRulesets(rulesetId, projectId, memo, _msgSender());
    }

    /// @notice Mint new project tokens into an account, optionally reserving a portion according to the current
    /// ruleset's reserved rate.
    /// @dev Only a project's owner, an operator with the `MINT_TOKENS` permission from them, one of the project's
    /// terminals, or its current data hook can mint a project's tokens.
    /// @dev If the ruleset has discretionary minting disabled, this function can only be called by the terminal or data
    /// hook.
    /// @param projectId The ID of the project the tokens being minted belong to.
    /// @param tokenCount The total number of tokens to mint, including any tokens that will be reserved.
    /// @param beneficiary The account which will receive the (non-reserved) minted tokens.
    /// @param memo A memo to pass along to the emitted event.
    /// @param useReservedRate Whether to use the current ruleset's reserved rate in the minting calculations.
    /// @return beneficiaryTokenCount The number of tokens minted for the beneficiary.
    function mintTokensOf(
        uint256 projectId,
        uint256 tokenCount,
        address beneficiary,
        string calldata memo,
        bool useReservedRate
    )
        external
        virtual
        override
        returns (uint256 beneficiaryTokenCount)
    {
        // There should be tokens to mint.
        if (tokenCount == 0) revert ZERO_TOKENS_TO_MINT();

        // Keep a reference to the reserved rate to use
        uint256 reservedRate;

        // Get a reference to the project's current ruleset.
        JBRuleset memory ruleset = RULESETS.currentOf(projectId);

        // Minting limited to: project owner, operators with the `MINT_TOKENS` permission from the owner, the
        // project's terminals, or the project's current ruleset data hook
        _requirePermissionAllowingOverrideFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.MINT_TOKENS,
            alsoGrantAccessIf: DIRECTORY.isTerminalOf(projectId, IJBTerminal(_msgSender()))
                || _msgSender() == ruleset.dataHook()
                || (
                    ruleset.dataHook() != address(0)
                        && IJBRulesetDataHook(ruleset.dataHook()).hasMintPermissionFor(projectId, _msgSender())
                )
        });

        // If the message sender is not a terminal or a data hook, the current ruleset must allow minting if there is
        // one.
        if (
            ruleset.id != 0 && !ruleset.allowOwnerMinting()
                && !DIRECTORY.isTerminalOf(projectId, IJBTerminal(_msgSender()))
                && _msgSender() != address(ruleset.dataHook())
                && (
                    ruleset.dataHook() == address(0)
                        || !IJBRulesetDataHook(ruleset.dataHook()).hasMintPermissionFor(projectId, _msgSender())
                )
        ) revert MINT_NOT_ALLOWED_AND_NOT_TERMINAL_OR_HOOK();

        // Determine the reserved rate to use.
        reservedRate = useReservedRate ? ruleset.reservedRate() : 0;

        if (reservedRate != JBConstants.MAX_RESERVED_RATE) {
            // The unreserved number of tokens that will be minted to the beneficiary.
            beneficiaryTokenCount =
                mulDiv(tokenCount, JBConstants.MAX_RESERVED_RATE - reservedRate, JBConstants.MAX_RESERVED_RATE);

            // Mint the tokens.
            TOKENS.mintFor(beneficiary, projectId, beneficiaryTokenCount);
        }

        // Add reserved tokens to the pending balance if needed
        if (reservedRate > 0) {
            pendingReservedTokenBalanceOf[projectId] += tokenCount - beneficiaryTokenCount;
        }

        emit MintTokens(beneficiary, projectId, tokenCount, beneficiaryTokenCount, memo, reservedRate, _msgSender());
    }

    /// @notice Burns a project's tokens from a specific holder's balance.
    /// @dev Only a token holder, an operator with the `BURN_TOKENS` permission from them, or a project's terminal can
    /// burn a holder's tokens.
    /// @param holder The account whose tokens are being burned.
    /// @param projectId The ID of the project that the tokens being burned belong to.
    /// @param tokenCount The number of tokens to burn.
    /// @param memo A memo to pass along to the emitted event.
    function burnTokensOf(
        address holder,
        uint256 projectId,
        uint256 tokenCount,
        string calldata memo
    )
        external
        virtual
        override
    {
        // Enforce permissions.
        _requirePermissionAllowingOverrideFrom({
            account: holder,
            projectId: projectId,
            permissionId: JBPermissionIds.BURN_TOKENS,
            alsoGrantAccessIf: DIRECTORY.isTerminalOf(projectId, IJBTerminal(_msgSender()))
        });

        // There should be tokens to burn
        if (tokenCount == 0) revert NO_BURNABLE_TOKENS();

        // Burn the tokens.
        TOKENS.burnFrom(holder, projectId, tokenCount);

        emit BurnTokens(holder, projectId, tokenCount, memo, _msgSender());
    }

    /// @notice Sends a project's pending reserved tokens to its reserved token splits.
    /// @dev If the project has no reserved token splits, or they don't add up to 100%, the leftover tokens are minted
    /// to the project's owner.
    /// @param projectId The ID of the project to which the reserved tokens belong.
    /// @param memo A memo to pass along to the emitted event.
    /// @return The amount of reserved tokens minted and sent.
    function sendReservedTokensToSplitsOf(
        uint256 projectId,
        string calldata memo
    )
        external
        virtual
        override
        returns (uint256)
    {
        return _sendReservedTokensToSplitsOf(projectId, memo);
    }

    /// @notice Allows other controllers to signal to this one that a migration is expected for the specified project.
    /// @dev This controller should not yet be the project's controller.
    /// @param from The controller being migrated from.
    /// @param projectId The ID of the project that will be migrated to this controller.
    function receiveMigrationFrom(IERC165 from, uint256 projectId) external virtual override {
        projectId; // Prevents unused var compiler and natspec complaints.
        from; // Prevents unused var compiler and natspec complaints.

        // Copy the main metadata if relevant.
        if (
            from.supportsInterface(type(IJBProjectMetadataRegistry).interfaceId)
                && DIRECTORY.controllerOf(projectId) == from
        ) {
            metadataOf[projectId] = IJBProjectMetadataRegistry(address(from)).metadataOf(projectId);
        }
    }

    /// @notice Allows a project to migrate from this controller to another one.
    /// @dev Only a project's owner or an operator with the `MIGRATE_CONTROLLER` permission from the owner can migrate
    /// it.
    /// @param projectId The ID of the project that will be migrated from this controller.
    /// @param to The controller the project is migrating to.
    function migrateController(uint256 projectId, IJBMigratable to) external virtual override {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.MIGRATE_CONTROLLER
        });

        // Get a reference to the project's current ruleset.
        JBRuleset memory ruleset = RULESETS.currentOf(projectId);

        // Migration must be allowed.
        if (!ruleset.allowControllerMigration()) {
            revert CONTROLLER_MIGRATION_NOT_ALLOWED();
        }

        // All reserved tokens must be minted before migrating.
        if (pendingReservedTokenBalanceOf[projectId] != 0) {
            _sendReservedTokensToSplitsOf(projectId, "");
        }

        // Make sure the new controller is prepped for the migration.
        to.receiveMigrationFrom(IERC165(this), projectId);

        emit MigrateController(projectId, to, _msgSender());
    }

    /// @notice Set a project's metadata content.
    /// @dev Only a project's owner can set its metadata through the project's controller.
    /// @dev Frontends typically use an IPFS hash for the metadata content.
    /// @param projectId The ID of the project to set the metadata of.
    /// @param metadata The metadata content to set.
    function setMetadataOf(uint256 projectId, string calldata metadata) external override {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_PROJECT_METADATA
        });

        // Set the project's new metadata content.
        metadataOf[projectId] = metadata;

        emit SetMetadata(projectId, metadata, _msgSender());
    }

    /// @notice Sets a project's split groups.
    /// @dev Only a project's owner or an operator with `SET_SPLITS` permission from the owner can set its splits
    /// through the project's controller.
    /// @dev The new split groups must include any currently set splits that are locked.
    /// @param projectId The ID of the project split groups are being set for.
    /// @param rulesetId The ID of the ruleset the split groups should be active in. Use a `rulesetId` of 0 to set the
    /// default split groups which are active when a project's ruleset has no splits set. If no default splits have been
    /// set, all splits are sent to the project's owner.
    /// @param splitGroups An array of split groups to set.
    function setSplitGroupsOf(
        uint256 projectId,
        uint256 rulesetId,
        JBSplitGroup[] calldata splitGroups
    )
        external
        virtual
        override
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_SPLITS
        });

        // Set splits for the group.
        SPLITS.setSplitGroupsOf(projectId, rulesetId, splitGroups);
    }

    /// @notice Deploys an ERC-20 token for a project. It will be used when claiming tokens (with credits).
    /// @dev Deploys a project's ERC-20 token contract.
    /// @dev Only a project's owner or an operator with `ISSUE_TOKENS` permission from the owner can deploy its token.
    /// @param projectId The ID of the project to deploy an ERC-20 token for.
    /// @param name The ERC-20's name.
    /// @param symbol The ERC-20's symbol.
    /// @return token The address of the token that was deployed.
    function deployERC20For(
        uint256 projectId,
        string calldata name,
        string calldata symbol
    )
        external
        virtual
        override
        returns (IJBToken token)
    {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.ISSUE_TOKEN
        });

        return TOKENS.deployERC20For(projectId, name, symbol);
    }

    /// @notice Set a project's token if not already set.
    /// @dev Only a project's owner or an operator with `SET_TOKEN` permission from the owner can set its token.
    /// @param projectId The ID of the project to set the token of.
    /// @param token The new token's address.
    function setTokenFor(uint256 projectId, IJBToken token) external virtual override {
        // Enforce permissions.
        _requirePermissionFrom({
            account: PROJECTS.ownerOf(projectId),
            projectId: projectId,
            permissionId: JBPermissionIds.SET_TOKEN
        });

        TOKENS.setTokenFor(projectId, token);
    }

    /// @notice Redeem credits to claim tokens into a holder's wallet.
    /// @dev Only a credit holder or an operator with the `CLAIM_TOKENS` permission from that holder can redeem those
    /// credits to claim tokens.
    /// @param holder The owner of the credits being redeemed.
    /// @param projectId The ID of the project whose tokens are being claimed.
    /// @param amount The amount of tokens to claim.
    /// @param beneficiary The account into which the claimed tokens will go.
    function claimTokensFor(
        address holder,
        uint256 projectId,
        uint256 amount,
        address beneficiary
    )
        external
        virtual
        override
    {
        // Enforce permissions.
        _requirePermissionFrom({account: holder, projectId: projectId, permissionId: JBPermissionIds.CLAIM_TOKENS});

        TOKENS.claimTokensFor(holder, projectId, amount, beneficiary);
    }

    /// @notice Allows a holder to transfer credits to another account.
    /// @dev Only a credit holder or an operator with the `TRANSFER_TOKENS` permission from that holder can transfer
    /// those credits.
    /// @param holder The address to transfer credits from.
    /// @param projectId The ID of the project whose credits are being transferred.
    /// @param recipient The recipient of the credits.
    /// @param amount The amount of credits to transfer.
    function transferCreditsFrom(
        address holder,
        uint256 projectId,
        address recipient,
        uint256 amount
    )
        external
        virtual
        override
    {
        // Enforce permissions.
        _requirePermissionFrom({account: holder, projectId: projectId, permissionId: JBPermissionIds.TRANSFER_TOKENS});

        // Get a reference to the current ruleset for the project.
        JBRuleset memory ruleset = RULESETS.currentOf(projectId);

        // Credit transfers must not be paused.
        if (ruleset.pauseCreditTransfers()) revert CREDIT_TRANSFERS_PAUSED();

        TOKENS.transferCreditsFrom(holder, projectId, recipient, amount);
    }

    //*********************************************************************//
    // ---------------------- internal transactions ---------------------- //
    //*********************************************************************//

    /// @notice Returns the sender, prefered to use over `_msgSender()`
    /// @return sender the sender address of this call.
    function _msgSender() internal view override(ERC2771Context, Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    /// @notice Returns the calldata, prefered to use over `msg.data`
    /// @return calldata the `msg.data` of this call
    function _msgData() internal view override(ERC2771Context, Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    /// @dev ERC-2771 specifies the context as being a single address (20 bytes).
    function _contextSuffixLength() internal view virtual override(ERC2771Context, Context) returns (uint256) {
        return super._contextSuffixLength();
    }

    //*********************************************************************//
    // ---------------------- private transactions ----------------------- //
    //*********************************************************************//

    /// @notice Sends pending reserved tokens to the project's reserved token splits.
    /// @dev If the project has no reserved token splits, or they don't add up to 100%, the leftover tokens are minted
    /// to the project's owner.
    /// @param projectId The ID of the project the reserved tokens belong to.
    /// @param memo A memo to pass along to the emitted event.
    /// @return tokenCount The number of reserved tokens minted/sent.
    function _sendReservedTokensToSplitsOf(
        uint256 projectId,
        string memory memo
    )
        private
        returns (uint256 tokenCount)
    {
        // Get the current ruleset to read the reserved rate from.
        JBRuleset memory ruleset = RULESETS.currentOf(projectId);

        // Get a reference to the number of tokens that need to be minted.
        tokenCount = pendingReservedTokenBalanceOf[projectId];

        // Reset the reserved token balance
        pendingReservedTokenBalanceOf[projectId] = 0;

        // Get a reference to the project owner.
        address owner = PROJECTS.ownerOf(projectId);

        // Send tokens to splits and get a reference to the leftover amount to mint after all splits have gotten their
        // share.
        uint256 leftoverTokenCount = tokenCount == 0
            ? 0
            : _sendTokensToSplitGroupOf(projectId, ruleset.id, JBSplitGroupIds.RESERVED_TOKENS, tokenCount);

        // Mint any leftover tokens to the project owner.
        if (leftoverTokenCount > 0) {
            TOKENS.mintFor(owner, projectId, leftoverTokenCount);
        }

        emit SendReservedTokensToSplits(
            ruleset.id, ruleset.cycleNumber, projectId, owner, tokenCount, leftoverTokenCount, memo, _msgSender()
        );
    }

    /// @notice Send `_amount` project tokens to the specified group of splits.
    /// @dev This is used to send reserved tokens to the reserved token splits.
    /// @param projectId The ID of the project that the split group belongs to.
    /// @param rulesetId The ID of the ruleset of the group to send tokens to.
    /// @param groupId The group of the splits to send the tokens between.
    /// @param amount The total number of tokens to sent.
    /// @return leftoverAmount If the splits percents dont add up to 100%, the leftover amount is returned.
    function _sendTokensToSplitGroupOf(
        uint256 projectId,
        uint256 rulesetId,
        uint256 groupId,
        uint256 amount
    )
        private
        returns (uint256 leftoverAmount)
    {
        // Set the leftover amount to the initial amount.
        leftoverAmount = amount;

        // Get a reference to the specified split group.
        JBSplit[] memory splits = SPLITS.splitsOf(projectId, rulesetId, groupId);

        // Keep a reference to the number of splits being iterated on.
        uint256 numberOfSplits = splits.length;

        //Transfer between all splits.
        for (uint256 i; i < numberOfSplits; i++) {
            // Get a reference to the split being iterated on.
            JBSplit memory split = splits[i];

            // Calculate the amount to send towards the split.
            uint256 tokenCount = mulDiv(amount, split.percent, JBConstants.SPLITS_TOTAL_PERCENT);

            // Mints tokens for the split if needed.
            if (tokenCount > 0) {
                // If a `hook` is set in the splits, set it as the beneficiary.
                // Otherwise, if a `projectId` is set in the split, set the project's owner as the beneficiary.
                // Otherwise, if the split has a beneficiary send to the split's beneficiary.
                // Otherwise, send to the `_msgSender()`.
                address _benenficiary = split.hook != IJBSplitHook(address(0))
                    ? address(split.hook)
                    : split.projectId != 0
                        ? PROJECTS.ownerOf(split.projectId)
                        : split.beneficiary != address(0) ? split.beneficiary : _msgSender();

                // Mint the tokens.
                TOKENS.mintFor(_benenficiary, projectId, tokenCount);

                // If there's a split hook, trigger its `processSplitWith` function.
                if (split.hook != IJBSplitHook(address(0))) {
                    // Get a reference to the project's token.
                    IJBToken token = TOKENS.tokenOf(projectId);

                    // Process.
                    split.hook.processSplitWith(
                        JBSplitHookContext({
                            token: address(token),
                            amount: tokenCount,
                            decimals: token.decimals(),
                            projectId: projectId,
                            groupId: groupId,
                            split: split
                        })
                    );
                }

                // Subtract from the amount to be sent to the beneficiary.
                leftoverAmount = leftoverAmount - tokenCount;
            }

            emit SendReservedTokensToSplit(projectId, rulesetId, groupId, split, tokenCount, _msgSender());
        }
    }

    /// @notice Queues one or more ruleset configurations and stores information pertinent to the configuration.
    /// @param projectId The ID of the project the rulesets are being queued for.
    /// @param rulesetConfigurations Configurations for the rulesets being queued.
    /// @return rulesetId The ID of the last ruleset that was successfully queued.
    function _queueRulesets(
        uint256 projectId,
        JBRulesetConfig[] calldata rulesetConfigurations
    )
        private
        returns (uint256 rulesetId)
    {
        // Keep a reference to the number of ruleset configurations being queued.
        uint256 numberOfConfigurations = rulesetConfigurations.length;

        // Keep a reference to the ruleset config being iterated on.
        JBRulesetConfig memory rulesetConfig;

        for (uint256 i; i < numberOfConfigurations; i++) {
            // Get a reference to the ruleset config being iterated on.
            rulesetConfig = rulesetConfigurations[i];

            // Make sure the provided reserved rate is valid.
            if (rulesetConfig.metadata.reservedRate > JBConstants.MAX_RESERVED_RATE) {
                revert INVALID_RESERVED_RATE();
            }

            // Make sure the provided redemption rate is valid.
            if (rulesetConfig.metadata.redemptionRate > JBConstants.MAX_REDEMPTION_RATE) {
                revert INVALID_REDEMPTION_RATE();
            }

            // Make sure the provided base currency is valid.
            if (rulesetConfig.metadata.baseCurrency > type(uint32).max) {
                revert INVALID_BASE_CURRENCY();
            }

            // Use the configuration to queue the ruleset.
            JBRuleset memory ruleset = RULESETS.queueFor({
                projectId: projectId,
                duration: rulesetConfig.duration,
                weight: rulesetConfig.weight,
                decayRate: rulesetConfig.decayRate,
                approvalHook: rulesetConfig.approvalHook,
                metadata: JBRulesetMetadataResolver.packRulesetMetadata(rulesetConfig.metadata),
                mustStartAtOrAfter: rulesetConfig.mustStartAtOrAfter
            });

            // Set the configuration's split groups.
            SPLITS.setSplitGroupsOf(projectId, ruleset.id, rulesetConfig.splitGroups);

            // Set the configuration's fund access limits.
            FUND_ACCESS_LIMITS.setFundAccessLimitsFor(projectId, ruleset.id, rulesetConfig.fundAccessLimitGroups);

            // Return the ruleset's ID if this is the last configuration being queued.
            if (i == numberOfConfigurations - 1) {
                rulesetId = ruleset.id;
            }
        }
    }

    /// @notice Configure terminals for use.
    /// @param projectId The ID of the project configuring the terminals for use.
    /// @param terminalConfigs The terminal configurations to enact.
    function _configureTerminals(uint256 projectId, JBTerminalConfig[] calldata terminalConfigs) private {
        // Keep a reference to the number of terminals being configured.
        uint256 numberOfTerminalConfigs = terminalConfigs.length;

        // Set an array of terminals to populate.
        IJBTerminal[] memory terminals = new IJBTerminal[](numberOfTerminalConfigs);

        // Keep a reference to the terminal configuration being iterated on.
        JBTerminalConfig memory terminalConfig;

        for (uint256 i; i < numberOfTerminalConfigs; i++) {
            // Set the terminal configuration being iterated on.
            terminalConfig = terminalConfigs[i];

            // Set the accounting contexts for the given tokens.
            terminalConfig.terminal.addAccountingContextsFor(projectId, terminalConfig.tokensToAccept);

            // Add the terminal.
            terminals[i] = terminalConfig.terminal;
        }

        // Set the terminals in the directory.
        if (numberOfTerminalConfigs > 0) {
            DIRECTORY.setTerminalsOf(projectId, terminals);
        }
    }
}
