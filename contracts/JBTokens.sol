// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import {EIP712} from '@openzeppelin/contracts/utils/cryptography/EIP712.sol';
import {JBControllerUtility} from './abstract/JBControllerUtility.sol';
import {JBOperatable} from './abstract/JBOperatable.sol';
import {IJBDirectory} from './interfaces/IJBDirectory.sol';
import {IJBRulesets} from './interfaces/IJBRulesets.sol';
import {IJBOperatorStore} from './interfaces/IJBOperatorStore.sol';
import {IJBProjects} from './interfaces/IJBProjects.sol';
import {IJBERC20Token} from './interfaces/IJBERC20Token.sol';
import {IJBTokens} from './interfaces/IJBTokens.sol';
import {JBFundingCycleMetadataResolver} from './libraries/JBFundingCycleMetadataResolver.sol';
import {JBOperations} from './libraries/JBOperations.sol';
import {JBRuleset} from './structs/JBRuleset.sol';
import {JBERC20Token} from './JBERC20Token.sol';

/// @notice Manages minting, burning, and balances of projects' tokens and token credits.
/// @dev Token balances can either be ERC-20s or token credits. This contract manages these two representations and allows credit -> ERC-20 claiming.
/// @dev The total supply of a project's tokens and the balance of each account are calculated in this contract.
/// @dev An ERC-20 contract must be set by a project's owner for ERC-20 claiming to become available. Projects can bring their own IJBERC20Token if they prefer.
contract JBTokens is JBControllerUtility, JBOperatable, IJBTokens {
  // A library that parses the packed funding cycle metadata into a friendlier format.
  using JBFundingCycleMetadataResolver for JBRuleset;

  //*********************************************************************//
  // --------------------------- custom errors ------------------------- //
  //*********************************************************************//
  error TOKEN_ALREADY_SET();
  error EMPTY_NAME();
  error EMPTY_SYMBOL();
  error EMPTY_TOKEN();
  error INSUFFICIENT_FUNDS();
  error INSUFFICIENT_CREDITS();
  error PROJECT_ALREADY_HAS_TOKEN();
  error RECIPIENT_ZERO_ADDRESS();
  error TOKEN_NOT_FOUND();
  error TOKENS_MUST_HAVE_18_DECIMALS();
  error CREDIT_TRANSFERS_PAUSED();
  error OVERFLOW_ALERT();

  //*********************************************************************//
  // ---------------- public immutable stored properties --------------- //
  //*********************************************************************//

  /// @notice Mints ERC-721s that represent project ownership and transfers.  
  IJBProjects public immutable override projects;

  /// @notice The contract storing all rulesets.
  IJBRulesets public immutable override rulesets;

  //*********************************************************************//
  // --------------------- public stored properties -------------------- //
  //*********************************************************************//

  /// @notice Each project's attached token contract.
  /// @custom:param _projectId The ID of the project the token belongs to. 
  mapping(uint256 => IJBERC20Token) public override tokenOf;

  /// @notice Each token's project.
  /// @custom:param _token The address of the token associated with the project.
  mapping(IJBERC20Token => uint256) public override projectIdOf;

  /// @notice The total supply of credits for each project.
  /// @custom:param _projectId The ID of the project to which the credits belong.
  mapping(uint256 => uint256) public override totalCreditSupplyOf;

  /// @notice Each holder's credit balance for each project.
  /// @custom:param _holder The credit holder.
  /// @custom:param _projectId The ID of the project to which the credits belong.
  mapping(address => mapping(uint256 => uint256)) public override creditBalanceOf;

  //*********************************************************************//
  // ------------------------- external views -------------------------- //
  //*********************************************************************//

  /// @notice The total balance a holder has for a specified project, including both tokens and token credits.
  /// @param _holder The holder to get a balance for.
  /// @param _projectId The project to get the `_holder`s balance for.
  /// @return balance The combined token and token credit balance of the `_holder  
  function totalBalanceOf(address _holder, uint256 _projectId)
    external
    view
    override
    returns (uint256 balance)
  {
    // Get a reference to the holder's credits for the project.
    balance = creditBalanceOf[_holder][_projectId];

    // Get a reference to the project's current token.
    IJBERC20Token _token = tokenOf[_projectId];

    // If the project has a current token, add the holder's balance to the total.
    if (_token != IJBERC20Token(address(0))) balance = balance + _token.balanceOf(_holder, _projectId);
  }

  //*********************************************************************//
  // --------------------------- public views -------------------------- //
  //*********************************************************************//

  /// @notice The total supply for a specific project, including both tokens and token credits.
  /// @param _projectId The ID of the project to get the total supply of.
  /// @return totalSupply The total supply of the project's tokens and token credits.
  function totalSupplyOf(uint256 _projectId) public view override returns (uint256 totalSupply) {
    // Get a reference to the total supply of the project's credits
    totalSupply = totalCreditSupplyOf[_projectId];

    // Get a reference to the project's current token.
    IJBERC20Token _token = tokenOf[_projectId];

    // If the project has a current token, add its total supply to the total.
    if (_token != IJBERC20Token(address(0))) totalSupply = totalSupply + _token.totalSupply(_projectId);
  }

  //*********************************************************************//
  // -------------------------- constructor ---------------------------- //
  //*********************************************************************//

  /// @param _permissions A contract storing protocol permission assignments.
  /// @param _projects A contract which mints ERC-721's that represent project ownership and transfers.
  /// @param _directory A contract storing directories of terminals and controllers for each project.
  /// @param _rulesets A contract storing project rulesets.
  constructor(
    IJBOperatorStore _permissions,
    IJBProjects _projects,
    IJBDirectory _directory,
    IJBRulesets _rulesets
  ) JBOperatable(_permissions) JBControllerUtility(_directory) {
    projects = _projects;
    rulesets = _rulesets;
  }

  //*********************************************************************//
  // ---------------------- external transactions ---------------------- //
  //*********************************************************************//

  /// @notice Deploys an ERC-20 token for a project. It will be used when claiming tokens.
  /// @dev Deploys a project's ERC-20 token contract.
  /// @dev Only a project's owner or operator can issue its token.
  /// @param _projectId The ID of the project to deploy an ERC-20 token for.
  /// @param _name The ERC-20's name.
  /// @param _symbol The ERC-20's symbol.
  /// @return token The address of the token that was issued.
  function deployERC20TokenFor(
    uint256 _projectId,
    string calldata _name,
    string calldata _symbol
  )
    external
    override
    requirePermission(projects.ownerOf(_projectId), _projectId, JBOperations.ISSUE_TOKEN)
    returns (IJBERC20Token token)
  {
    // There must be a name.
    if (bytes(_name).length == 0) revert EMPTY_NAME();

    // There must be a symbol.
    if (bytes(_symbol).length == 0) revert EMPTY_SYMBOL();
  
    // The project shouldn't already have a token.
    if (tokenOf[_projectId] != IJBERC20Token(address(0))) revert PROJECT_ALREADY_HAS_TOKEN();

    // Deploy the token contract.
    token = new JBERC20Token(_name, _symbol, _projectId, address(this));

    // Store the token contract.
    tokenOf[_projectId] = token;

    // Store the project for the token.
    projectIdOf[token] = _projectId;

    emit DeployERC20Token(_projectId, token, _name, _symbol, msg.sender);
  }

  /// @notice Set a project's token if not already set.
  /// @dev Only a project's owner or operator can set its token.
  /// @param _projectId The ID of the project to set the token of.
  /// @param _token The new token's address.
  function setTokenFor(uint256 _projectId, IJBERC20Token _token)
    external
    override
    requirePermission(projects.ownerOf(_projectId), _projectId, JBOperations.SET_TOKEN)
  {
    // Can't set to the zero address.
    if (_token == IJBERC20Token(address(0))) revert EMPTY_TOKEN();

    // Can't set a token if the project is already associated with another token.
    if (tokenOf[_projectId] != IJBERC20Token(address(0))) revert TOKEN_ALREADY_SET();

    // Can't set a token if it's already associated with another project.
    if (projectIdOf[_token] != 0) revert TOKEN_ALREADY_SET();

    // Can't change to a token that doesn't use 18 decimals.
    if (_token.decimals() != 18) revert TOKENS_MUST_HAVE_18_DECIMALS();

    // Store the new token.
    tokenOf[_projectId] = _token;

    // Store the project for the token.
    projectIdOf[_token] = _projectId;

    emit SetToken(_projectId, _token, msg.sender);
  }

  /// @notice Mint (create) new tokens or credits.
  /// @dev Only a project's current controller can mint its tokens.
  /// @param _holder The address receiving the new tokens.
  /// @param _projectId The ID of the project to which the tokens belong.
  /// @param _amount The amount of tokens to mint.
  function mintFor(
    address _holder,
    uint256 _projectId,
    uint256 _amount
  ) external override onlyController(_projectId) {
    // Get a reference to the project's current token.
    IJBERC20Token _token = tokenOf[_projectId];

    // Save a reference to whether there a token exists.
    bool _shouldClaimTokens = _token != IJBERC20Token(address(0));

    if (_shouldClaimTokens)
      // If tokens should be claimed, mint tokens into the holder's wallet.
      _token.mint(_projectId, _holder, _amount);
    else {
      // Otherwise, add the tokens to their credits and the credit supply.
      creditBalanceOf[_holder][_projectId] = creditBalanceOf[_holder][_projectId] + _amount;
      totalCreditSupplyOf[_projectId] = totalCreditSupplyOf[_projectId] + _amount;
    }

    // The total supply can't exceed the maximum value storable in a uint224.
    if (totalSupplyOf(_projectId) > type(uint224).max) revert OVERFLOW_ALERT();

    emit Mint(_holder, _projectId, _amount, _shouldClaimTokens, msg.sender);
  }

  /// @notice Burns (destroys) credits or tokens.
  /// @dev Credits are burned first, then tokens are burned.
  /// @dev Only a project's current controller can burn its tokens.
  /// @param _holder The address that owns the tokens which are being burned.
  /// @param _projectId The ID of the project to the burned tokens belong to.
  /// @param _amount The amount of tokens to burn.
  function burnFrom(
    address _holder,
    uint256 _projectId,
    uint256 _amount
  ) external override onlyController(_projectId) {
    // Get a reference to the project's current token.
    IJBERC20Token _token = tokenOf[_projectId];

    // Get a reference to the amount of credits the holder has.
    uint256 _creditBalance = creditBalanceOf[_holder][_projectId];

    // Get a reference to the amount of the project's current token the holder has in their wallet.
    uint256 _tokenBalance = _token == IJBERC20Token(address(0))
      ? 0
      : _token.balanceOf(_holder, _projectId);

    // There must be enough tokens to burn across the holder's combined token and credit balance.
    if (_amount > _tokenBalance + _creditBalance) revert INSUFFICIENT_FUNDS();

    // The amount of tokens to burn.
    uint256 _tokensToBurn;

    // Get a reference to how many tokens should be burned
    if (_tokenBalance != 0) {
      // Burn credits before tokens.
      unchecked {
        _tokensToBurn = _creditBalance < _amount ? _amount - _creditBalance : 0;
      }
    }

    // The amount of credits to burn.
    uint256 _creditsToBurn;
    unchecked {
      _creditsToBurn = _amount - _tokensToBurn;
    }

    // Subtract the burned credits from the credit balance and credit supply.
    if (_creditsToBurn > 0) {
      creditBalanceOf[_holder][_projectId] =
        creditBalanceOf[_holder][_projectId] -
        _creditsToBurn;
      totalCreditSupplyOf[_projectId] =
        totalCreditSupplyOf[_projectId] -
        _creditsToBurn;
    }

    // Burn the tokens.
    if (_tokensToBurn > 0) _token.burn(_projectId, _holder, _tokensToBurn);

    emit Burn(
      _holder,
      _projectId,
      _amount,
      _creditBalance,
      _tokenBalance,
      msg.sender
    );
  }

  /// @notice Redeem credits to claim tokens into a holder's wallet.
  /// @dev Only a credit holder or an operator specified by that holder can redeem credits to claim tokens.
  /// @param _holder The owner of the credits being redeemed.
  /// @param _projectId The ID of the project whose tokens are being claimed.
  /// @param _amount The amount of tokens to claim.
  /// @param _beneficiary The account into which the claimed tokens will go.
  function claimTokensFor(
    address _holder,
    uint256 _projectId,
    uint256 _amount,
    address _beneficiary
  ) external override requirePermission(_holder, _projectId, JBOperations.CLAIM_TOKENS) {
    // Get a reference to the project's current token.
    IJBERC20Token _token = tokenOf[_projectId];

    // The project must have a token contract attached.
    if (_token == IJBERC20Token(address(0))) revert TOKEN_NOT_FOUND();

    // Get a reference to the amount of credits the holder has.
    uint256 _creditBalance = creditBalanceOf[_holder][_projectId];

    // There must be enough credits to claim.
    if (_creditBalance < _amount) revert INSUFFICIENT_CREDITS();

    unchecked {
      // Subtract the claim amount from the holder's credit balance.
      creditBalanceOf[_holder][_projectId] = _creditBalance - _amount;

      // Subtract the claim amount from the project's total credit supply.
      totalCreditSupplyOf[_projectId] = totalCreditSupplyOf[_projectId] - _amount;
    }

    // Mint the equivalent amount of the project's token for the holder.
    _token.mint(_projectId, _beneficiary, _amount);

    emit ClaimTokens(_holder, _projectId, _creditBalance, _amount, _beneficiary, msg.sender);
  }

  /// @notice Allows a holder to transfer credits to another account.
  /// @dev Only a credit holder or an operator specified by that holder can transfer their credits.
  /// @param _holder The address to transfer credits from.
  /// @param _projectId The ID of the project whose credits are being transferred.
  /// @param _recipient The recipient of the credits.
  /// @param _amount The amount of credits to transfer.
  function transferCreditsFrom(
    address _holder,
    uint256 _projectId,
    address _recipient,
    uint256 _amount
  ) external override requirePermission(_holder, _projectId, JBOperations.TRANSFER_TOKENS) {
    // Get a reference to the project's current ruleset.
    JBRuleset memory _ruleset = rulesets.currentOf(_projectId);

    // Credit transfers must not be paused.
    if (_ruleset.global().pauseTransfers) revert CREDIT_TRANSFERS_PAUSED();

    // Can't transfer to the zero address.
    if (_recipient == address(0)) revert RECIPIENT_ZERO_ADDRESS();

    // Get a reference to the holder's unclaimed project token balance.
    uint256 _creditBalance = creditBalanceOf[_holder][_projectId];

    // The holder must have enough unclaimed tokens to transfer.
    if (_amount > _creditBalance) revert INSUFFICIENT_CREDITS();

    // Subtract from the holder's unclaimed token balance.
    unchecked {
      creditBalanceOf[_holder][_projectId] = _creditBalance - _amount;
    }

    // Add the unclaimed project tokens to the recipient's balance.
    creditBalanceOf[_recipient][_projectId] =
      creditBalanceOf[_recipient][_projectId] +
      _amount;

    emit TransferCredits(_holder, _projectId, _recipient, _amount, msg.sender);
  }
}
