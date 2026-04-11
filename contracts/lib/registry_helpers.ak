// Cardano Lending Protocol - Registry Helper Library
// Developed by grae.one (utxotools.io)
//
// Version: 8.0.0 - Registry Pattern Helpers
// License: Apache-2.0
//
// Helper functions for interacting with the centralized Registry.
// All validators use these functions to load and validate protocol
// configuration from the Registry UTxO via reference inputs.

use aiken/collection/list
use lending/types.{Operation, PendingUpdate, RegistryDatum}
use cardano/address.{Address, Script, from_script}
use cardano/transaction.{InlineDatum, Input}

// =============================================================================
// SECTION: Registry Loading
// =============================================================================

/// Load and parse the RegistryDatum from the transaction's reference inputs.
///
/// This is the primary entry point used by all validators to obtain
/// protocol configuration. The registry UTxO must be included as a
/// reference input with a matching script hash.
///
/// Example:
///   let registry = load_registry(tx.reference_inputs, params.registry_script_hash)
pub fn load_registry(
  reference_inputs: List<Input>,
  registry_hash: ByteArray,
) -> RegistryDatum {
  expect Some(registry_input) =
    list.find(
      reference_inputs,
      fn(input) {
        when input.output.address.payment_credential is {
          Script(hash) -> hash == registry_hash
          _ -> False
        }
      },
    )
  expect InlineDatum(registry_data) = registry_input.output.datum
  expect registry: RegistryDatum = registry_data
  registry
}

// =============================================================================
// SECTION: Emergency and Pause Checks
// =============================================================================

/// Check if the protocol is NOT in emergency shutdown mode.
/// Returns True if the protocol is operational.
pub fn check_not_shutdown(registry: RegistryDatum) -> Bool {
  !registry.emergency_shutdown
}

/// Check if a specific operation type is currently allowed (not paused).
/// Returns True if the operation is permitted.
pub fn is_operation_allowed(
  registry: RegistryDatum,
  operation: Operation,
) -> Bool {
  !list.has(registry.paused_operations, operation)
}

/// Validate that the protocol is both operational and the specific operation
/// is not paused. Combines emergency shutdown and operation pause checks.
pub fn validate_operation(registry: RegistryDatum, operation: Operation) -> Bool {
  check_not_shutdown(registry) && is_operation_allowed(registry, operation)
}

// =============================================================================
// SECTION: Module Authorization
// =============================================================================

/// Check if a given script hash belongs to an authorized protocol module.
/// Used to verify that only official protocol contracts can interact in
/// certain code paths (e.g., fee distribution).
pub fn is_authorized_module(
  module_hash: ByteArray,
  registry: RegistryDatum,
) -> Bool {
  or {
    module_hash == registry.lending_pool_hash,
    or {
      module_hash == registry.orderbook_hash,
      or {
        module_hash == registry.position_hash,
        or {
          module_hash == registry.staking_hash,
          or {
            module_hash == registry.treasury_hash,
            module_hash == registry.oracle_hash,
          },
        },
      },
    },
  }
}

/// Verify that a transaction input originates from an authorized protocol module.
pub fn verify_authorized_input(input: Input, registry: RegistryDatum) -> Bool {
  when input.output.address.payment_credential is {
    Script(hash) -> is_authorized_module(hash, registry)
    _ -> False
  }
}

// =============================================================================
// SECTION: Fee Calculations
// =============================================================================

/// Calculate a fee amount using basis points (1 bps = 0.01%).
pub fn calculate_protocol_fee(amount: Int, fee_bps: Int) -> Int {
  amount * fee_bps / 10000
}

/// Calculate the staker allocation from collected fees.
pub fn calculate_staking_allocation(
  total_fees: Int,
  registry: RegistryDatum,
) -> Int {
  total_fees * registry.staking_share_bps / 10000
}

/// Calculate the treasury allocation from collected fees.
pub fn calculate_treasury_allocation(
  total_fees: Int,
  registry: RegistryDatum,
) -> Int {
  total_fees * registry.treasury_share_bps / 10000
}

/// Calculate the LP (liquidity provider) allocation from collected fees.
pub fn calculate_lp_allocation(total_fees: Int, registry: RegistryDatum) -> Int {
  total_fees * registry.lp_share_bps / 10000
}

/// Validate that the fee distribution ratios sum to exactly 100% (10000 bps).
pub fn validate_fee_distribution(registry: RegistryDatum) -> Bool {
  let total_bps =
    registry.treasury_share_bps + registry.staking_share_bps + registry.lp_share_bps
  total_bps == 10000
}

// =============================================================================
// SECTION: Risk Parameter Validation
// =============================================================================

/// Validate that a collateral value meets the minimum collateral ratio.
pub fn validate_collateral_ratio(
  collateral_value: Int,
  borrow_amount: Int,
  registry: RegistryDatum,
) -> Bool {
  let collateral_ratio = collateral_value * 10000 / borrow_amount
  collateral_ratio >= registry.min_collateral_ratio_bps
}

/// Validate that a borrow rate does not exceed the maximum allowed rate.
pub fn validate_borrow_rate(rate_bps: Int, registry: RegistryDatum) -> Bool {
  rate_bps <= registry.max_borrow_rate_bps
}

/// Validate that pool utilization does not exceed the maximum allowed rate.
pub fn validate_utilization(
  total_borrowed: Int,
  total_deposited: Int,
  registry: RegistryDatum,
) -> Bool {
  if total_deposited == 0 {
    True
  } else {
    let utilization = total_borrowed * 10000 / total_deposited
    utilization <= registry.max_utilization_rate_bps
  }
}

// =============================================================================
// SECTION: Amount Validation
// =============================================================================

/// Validate that a deposit amount is within the allowed range.
pub fn validate_deposit_amount(amount: Int, registry: RegistryDatum) -> Bool {
  and {
    amount >= registry.min_deposit_amount,
    amount <= registry.max_single_deposit,
  }
}

/// Validate that a borrow amount is within the allowed range.
pub fn validate_borrow_amount(amount: Int, registry: RegistryDatum) -> Bool {
  and {
    amount >= registry.min_borrow_amount,
    amount <= registry.max_single_borrow,
  }
}

// =============================================================================
// SECTION: Oracle Freshness Checks
// =============================================================================

/// Check if oracle data is fresh enough for borrow operations.
/// Uses the configurable max_oracle_age_borrow from the registry.
pub fn is_oracle_fresh_for_borrow(
  oracle_timestamp: Int,
  current_time: Int,
  registry: RegistryDatum,
) -> Bool {
  let age = current_time - oracle_timestamp
  age <= registry.max_oracle_age_borrow
}

/// Check if oracle data is fresh enough for liquidation operations.
/// Uses the configurable max_oracle_age_liquidate from the registry.
pub fn is_oracle_fresh_for_liquidation(
  oracle_timestamp: Int,
  current_time: Int,
  registry: RegistryDatum,
) -> Bool {
  let age = current_time - oracle_timestamp
  age <= registry.max_oracle_age_liquidate
}

// =============================================================================
// SECTION: Batcher Deadline Helpers
// =============================================================================

/// Calculate the minimum order deadline based on current time plus buffer.
pub fn calculate_order_deadline(
  current_time: Int,
  registry: RegistryDatum,
) -> Int {
  current_time + registry.batcher_deadline_buffer
}

/// Validate that an order's deadline allows sufficient processing time.
pub fn validate_order_deadline(
  deadline: Int,
  current_time: Int,
  registry: RegistryDatum,
) -> Bool {
  let min_deadline = current_time + registry.batcher_deadline_buffer
  deadline >= min_deadline
}

// =============================================================================
// SECTION: Address Helpers
// =============================================================================

/// Get the lending pool script address from registry configuration.
pub fn get_pool_address(registry: RegistryDatum) -> Address {
  from_script(registry.lending_pool_hash)
}

/// Get the orderbook script address from registry configuration.
pub fn get_orderbook_address(registry: RegistryDatum) -> Address {
  from_script(registry.orderbook_hash)
}

/// Get the position script address from registry configuration.
pub fn get_position_address(registry: RegistryDatum) -> Address {
  from_script(registry.position_hash)
}

/// Get the staking script address from registry configuration.
pub fn get_staking_address(registry: RegistryDatum) -> Address {
  from_script(registry.staking_hash)
}

/// Get the treasury script address from registry configuration.
pub fn get_treasury_address(registry: RegistryDatum) -> Address {
  from_script(registry.treasury_hash)
}

/// Get the oracle script address from registry configuration.
pub fn get_oracle_address(registry: RegistryDatum) -> Address {
  from_script(registry.oracle_hash)
}

// =============================================================================
// SECTION: Governance Helpers
// =============================================================================

/// Check if the governance delay has passed for a pending update.
/// Returns True if the current time >= the update's activation time.
pub fn is_governance_delay_passed(
  current_time: Int,
  pending_update: PendingUpdate,
) -> Bool {
  current_time >= pending_update.activation_time
}

/// Check if the admin's signature is present in the transaction.
pub fn is_admin_signed(
  signatures: List<ByteArray>,
  registry: RegistryDatum,
) -> Bool {
  list.has(signatures, registry.admin_pkh)
}

// =============================================================================
// SECTION: Utility Functions
// =============================================================================

/// Create a summary tuple of registry state for debugging/logging.
/// Returns (version, emergency_shutdown, paused_operations_count).
pub fn registry_summary(registry: RegistryDatum) -> (Int, Bool, Int) {
  (
    registry.version,
    registry.emergency_shutdown,
    list.length(registry.paused_operations),
  )
}

/// Validate that the registry version meets a minimum compatibility requirement.
pub fn validate_registry_version(
  registry: RegistryDatum,
  min_version: Int,
) -> Bool {
  registry.version >= min_version
}
