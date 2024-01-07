// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC165} from "lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import {JBControlled} from "./abstract/JBControlled.sol";
import {IJBFundAccessLimits} from "./interfaces/IJBFundAccessLimits.sol";
import {IJBDirectory} from "./interfaces/IJBDirectory.sol";
import {JBFundAccessLimitGroup} from "./structs/JBFundAccessLimitGroup.sol";
import {JBCurrencyAmount} from "./structs/JBCurrencyAmount.sol";

/// @notice Stores and manages terminal fund access limits for each project.
/// @dev See the `JBFundAccessLimitGroup` struct to learn about payout limits and surplus allowances.
contract JBFundAccessLimits is JBControlled, ERC165, IJBFundAccessLimits {
    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error INVALID_PAYOUT_LIMIT();
    error INVALID_PAYOUT_LIMIT_CURRENCY();
    error INVALID_PAYOUT_LIMIT_CURRENCY_ORDERING();
    error INVALID_SURPLUS_ALLOWANCE();
    error INVALID_SURPLUS_ALLOWANCE_CURRENCY();
    error INVALID_SURPLUS_ALLOWANCE_CURRENCY_ORDERING();

    //*********************************************************************//
    // --------------------- private stored properties ------------------- //
    //*********************************************************************//

    /// @notice An array of packed payout limits for a given project, ruleset, terminal, and token.
    /// @dev bits 0-223: The maximum amount (in a specific currency) of the terminal's `token`s that the project can pay
    /// out during the applicable ruleset.
    /// @dev bits 224-255: The currency that the payout limit is denominated in. If this currency is different from the
    /// terminal's `token`, the payout limit will vary depending on their exchange rate.
    /// @custom:param projectId The ID of the project to get the packed payout limit data of.
    /// @custom:param rulesetId The ID of the ruleset that the packed payout limit data applies to.
    /// @custom:param terminal The terminal the payouts are being limited in.
    /// @custom:param token The token payouts are being limited for.
    mapping(
        uint256 projectId
            => mapping(uint256 rulesetId => mapping(address terminal => mapping(address token => uint256[])))
    ) private _packedPayoutLimitsDataOf;

    /// @notice An array of packed surplus allowances for a given project, ruleset, terminal, and token.
    /// @dev bits 0-223: The maximum amount (in a specific currency) of the terminal's `token`s that the project can
    /// access from its surplus during the applicable ruleset.
    /// @dev bits 224-255: The currency that the surplus allowance is denominated in. If this currency is different from
    /// the terminal's `token`, the surplus allowance will vary depending on their exchange rate.
    /// @custom:param projectId The ID of the project to get the packed surplus allowance data of.
    /// @custom:param rulesetId The ID of the ruleset that the packed surplus allowance data applies to.
    /// @custom:param terminal The terminal the surplus allowance comes from.
    /// @custom:param token The token that the surplus allowance applies to.
    mapping(
        uint256 projectId
            => mapping(uint256 rulesetId => mapping(address terminal => mapping(address token => uint256[])))
    ) private _packedSurplusAllowancesDataOf;

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice A project's payout limits for a given ruleset, terminal, and token.
    /// @notice The total value of `token`s that a project can pay out from the terminal during the ruleset is dictated
    /// by a list of payout limits. Each payout limit is in terms of its own amount and currency.
    /// @dev The fixed point `amount`s of the returned structs will have the same number of decimals as the specified
    /// terminal.
    /// @param projectId The ID of the project to get the payout limits of.
    /// @param rulesetId The ID of the ruleset the payout limits apply to.
    /// @param terminal The terminal the payout limits apply to.
    /// @param token The token the payout limits apply to.
    /// @return payoutLimits The payout limits.
    function payoutLimitsOf(
        uint256 projectId,
        uint256 rulesetId,
        address terminal,
        address token
    )
        external
        view
        override
        returns (JBCurrencyAmount[] memory payoutLimits)
    {
        // Get a reference to the packed data.
        uint256[] memory packedPayoutLimitsData = _packedPayoutLimitsDataOf[projectId][rulesetId][terminal][token];

        // Get a reference to the number of payout limits.
        uint256 numberOfData = packedPayoutLimitsData.length;

        // Initialize the return value.
        payoutLimits = new JBCurrencyAmount[](numberOfData);

        // Keep a reference to the data that'll be iterated.
        uint256 packedPayoutLimitData;

        // Iterate through the stored packed values and format the returned value.
        for (uint256 i; i < numberOfData; i++) {
            // Set the data being iterated on.
            packedPayoutLimitData = packedPayoutLimitsData[i];

            // The limit amount is in bits 0-231. The currency is in bits 224-255.
            payoutLimits[i] = JBCurrencyAmount({
                currency: packedPayoutLimitData >> 224,
                amount: uint256(uint224(packedPayoutLimitData))
            });
        }
    }

    /// @notice A project's payout limit for a specific currency and a given ruleset, terminal, and token.
    /// @dev The fixed point amount returned will have the same number of decimals as the specified terminal.
    /// @param projectId The ID of the project to get the payout limit of.
    /// @param rulesetId The ID of the ruleset the payout limit applies to.
    /// @param terminal The terminal the payout limit applies to.
    /// @param token The token the payout limit applies to.
    /// @param currency The currency the payout limit is denominated in.
    /// @return payoutLimit The payout limit, as a fixed point number with the same number of decimals as the provided
    /// terminal.
    function payoutLimitOf(
        uint256 projectId,
        uint256 rulesetId,
        address terminal,
        address token,
        uint256 currency
    )
        external
        view
        override
        returns (uint256 payoutLimit)
    {
        // Get a reference to the packed data.
        uint256[] memory data = _packedPayoutLimitsDataOf[projectId][rulesetId][terminal][token];

        // Get a reference to the number of payout limits.
        uint256 numberOfData = data.length;

        // Keep a reference to the data that'll be iterated.
        uint256 packedPayoutLimitData;

        // Iterate through the stored packed values and return the value of the matching currency.
        for (uint256 i; i < numberOfData; i++) {
            // Set the data being iterated on.
            packedPayoutLimitData = data[i];

            // If the currencies match, return the value.
            if (currency == packedPayoutLimitData >> 224) {
                return uint256(uint224(packedPayoutLimitData));
            }
        }
    }

    /// @notice A project's surplus allowances for a given ruleset, terminal, and token.
    /// @notice The total value of `token`s that a project can pay out from its surplus in a terminal during the
    /// ruleset is dictated by a list of surplus allowances. Each surplus allowance is in terms of its own amount and
    /// currency.
    /// @dev The number of decimals in the returned fixed point amount is the same as that of the specified terminal.
    /// @param projectId The ID of the project to get the surplus allowances of.
    /// @param rulesetId The ID of the ruleset the surplus allowances applies to.
    /// @param terminal The terminal the surplus allowances applies to.
    /// @param token The token the surplus allowances applies to.
    /// @return surplusAllowances The surplus allowances.
    function surplusAllowancesOf(
        uint256 projectId,
        uint256 rulesetId,
        address terminal,
        address token
    )
        external
        view
        override
        returns (JBCurrencyAmount[] memory surplusAllowances)
    {
        // Get a reference to the packed data.
        uint256[] memory packedSurplusAllowancesData =
            _packedSurplusAllowancesDataOf[projectId][rulesetId][terminal][token];

        // Get a reference to the number of surplus allowances.
        uint256 numberOfData = packedSurplusAllowancesData.length;

        // Initialize the return value.
        surplusAllowances = new JBCurrencyAmount[](numberOfData);

        // Keep a reference to the data that'll be iterated.
        uint256 packedSurplusAllowanceData;

        // Iterate through the stored packed values and format the returned value.
        for (uint256 i; i < numberOfData; i++) {
            // Set the data being iterated on.
            packedSurplusAllowanceData = packedSurplusAllowancesData[i];

            // The limit is in bits 0-223. The currency is in bits 224-255.
            surplusAllowances[i] = JBCurrencyAmount({
                currency: packedSurplusAllowanceData >> 224,
                amount: uint256(uint224(packedSurplusAllowanceData))
            });
        }
    }

    /// @notice A project's surplus allowance for a specific currency and a given ruleset, terminal, and token.
    /// @dev The fixed point amount returned will have the same number of decimals as the specified terminal.
    /// @param projectId The ID of the project to get the surplus allowance of.
    /// @param rulesetId The ID of the ruleset the surplus allowance applies to.
    /// @param terminal The terminal the surplus allowance applies to.
    /// @param token The token the surplus allowance applies to.
    /// @param currency The currency that the surplus allowance is denominated in.
    /// @return surplusAllowance The surplus allowance, as a fixed point number with the same number of decimals as the
    /// provided terminal.
    function surplusAllowanceOf(
        uint256 projectId,
        uint256 rulesetId,
        address terminal,
        address token,
        uint256 currency
    )
        external
        view
        override
        returns (uint256 surplusAllowance)
    {
        // Get a reference to the packed data.
        uint256[] memory packedSurplusAllowancesData =
            _packedSurplusAllowancesDataOf[projectId][rulesetId][terminal][token];

        // Get a reference to the number of surplus allowances.
        uint256 numberOfData = packedSurplusAllowancesData.length;

        // Keep a reference to the data that'll be iterated.
        uint256 packedSurplusAllowanceData;

        // Iterate through the stored packed values and format the returned value.
        for (uint256 i; i < numberOfData; i++) {
            // Set the data being iterated on.
            packedSurplusAllowanceData = packedSurplusAllowancesData[i];

            // If the currencies match, return the value.
            if (currency == packedSurplusAllowanceData >> 224) {
                return uint256(uint224(packedSurplusAllowanceData));
            }
        }
    }

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory A contract storing directories of terminals and controllers for each project.
    // solhint-disable-next-line no-empty-blocks
    constructor(IJBDirectory directory) JBControlled(directory) {}

    //*********************************************************************//
    // --------------------- external transactions ----------------------- //
    //*********************************************************************//

    /// @notice Sets limits for the amount of funds a project can access from its terminals during a ruleset.
    /// @dev Only a project's current controller can set its fund access limits.
    /// @dev Payout limits and surplus allowances must be specified in strictly increasing order (by currency) to
    /// prevent duplicates.
    /// @param projectId The ID of the project whose fund access limits are being set.
    /// @param rulesetId The ID of the ruleset that the limits will apply within.
    /// @param fundAccessLimitGroup An array containing payout limits and surplus allowances for each payment terminal.
    /// Amounts are fixed point numbers using the same number of decimals as the accompanying terminal.
    function setFundAccessLimitsFor(
        uint256 projectId,
        uint256 rulesetId,
        JBFundAccessLimitGroup[] calldata fundAccessLimitGroup
    )
        external
        override
        onlyControllerOf(projectId)
    {
        // Save the number of limits.
        uint256 numberOfFundAccessLimitGroups = fundAccessLimitGroup.length;

        // Keep a reference to the fund access constraint being iterated on.
        JBFundAccessLimitGroup calldata limits;

        // Set payout limits if there are any.
        for (uint256 i; i < numberOfFundAccessLimitGroups; i++) {
            // Set the limits being iterated on.
            limits = fundAccessLimitGroup[i];

            // Keep a reference to the number of payout limits.
            uint256 numberOfPayoutLimits = limits.payoutLimits.length;

            // Keep a reference to the payout limit being iterated on.
            JBCurrencyAmount calldata payoutLimit;

            // Iterate through each payout limit to validate and store them.
            for (uint256 j; j < numberOfPayoutLimits; j++) {
                // Set the payout limit being iterated on.
                payoutLimit = limits.payoutLimits[j];

                // If payout limit amount is larger than 224 bits, revert.
                if (payoutLimit.amount > type(uint224).max) {
                    revert INVALID_PAYOUT_LIMIT();
                }

                // If payout limit currency's index is larger than 32 bits, revert.
                if (payoutLimit.currency > type(uint32).max) {
                    revert INVALID_PAYOUT_LIMIT_CURRENCY();
                }

                // Make sure the payout limits are passed in increasing order of currency to prevent duplicates.
                if (j != 0 && payoutLimit.currency <= limits.payoutLimits[j - 1].currency) {
                    revert INVALID_PAYOUT_LIMIT_CURRENCY_ORDERING();
                }

                // Set the payout limit if there is one.
                if (payoutLimit.amount > 0) {
                    _packedPayoutLimitsDataOf[projectId][rulesetId][fundAccessLimitGroup[i].terminal][fundAccessLimitGroup[i]
                        .token].push(payoutLimit.amount | (payoutLimit.currency << 224));
                }
            }

            // Keep a reference to the number of surplus allowances.
            uint256 numberOfSurplusAllowances = limits.surplusAllowances.length;

            // Keep a reference to the surplus allowances being iterated on.
            JBCurrencyAmount calldata surplusAllowance;

            // Iterate through each surplus allowance to validate and store them.
            for (uint256 j; j < numberOfSurplusAllowances; j++) {
                // Set the payout limit being iterated on.
                surplusAllowance = limits.surplusAllowances[j];

                // If surplus allowance is larger than 224 bits, revert.
                if (surplusAllowance.amount > type(uint224).max) {
                    revert INVALID_SURPLUS_ALLOWANCE();
                }

                // If surplus allowance currency value is larger than 32 bits, revert.
                if (surplusAllowance.currency > type(uint32).max) {
                    revert INVALID_SURPLUS_ALLOWANCE_CURRENCY();
                }

                // Make sure the surplus allowances are passed in increasing order of currency to prevent duplicates.
                if (j != 0 && surplusAllowance.currency <= limits.surplusAllowances[j - 1].currency) {
                    revert INVALID_SURPLUS_ALLOWANCE_CURRENCY_ORDERING();
                }

                // Set the surplus allowance if there is one.
                if (surplusAllowance.amount > 0) {
                    _packedSurplusAllowancesDataOf[projectId][rulesetId][fundAccessLimitGroup[i].terminal][fundAccessLimitGroup[i]
                        .token].push(surplusAllowance.amount | (surplusAllowance.currency << 224));
                }
            }

            emit SetFundAccessLimits(rulesetId, projectId, limits, msg.sender);
        }
    }
}
