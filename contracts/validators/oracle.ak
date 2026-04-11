// Cardano Lending Protocol - Oracle Validator
// Developed by grae.one (utxotools.io)
//
// Version: 8.0.0 - Registry Pattern Compatible
// License: Apache-2.0
//
// Manages price feed data for the lending protocol. Authorized updaters
// can submit price updates subject to rate limits and sanity checks.
// Also provides utility functions for multi-oracle price aggregation.

use aiken/collection/list
use aiken/interval.{Finite}
use lending/types.{OracleData, OracleRedeemer}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, Input, OutputReference, Transaction}

// =============================================================================
// SECTION: Oracle Parameters
// =============================================================================

/// Configuration parameters for the oracle validator.
pub type OracleParams {
  /// List of authorized public key hashes that may submit price updates
  authorized_updaters: List<ByteArray>,
  /// Minimum time between consecutive price updates (milliseconds)
  min_update_interval: Int,
  /// Maximum allowed price change per update in basis points
  max_price_change: Int,
}

/// Minimum valid price (prevents zero/negative prices)
const min_price: Int = 1

/// Maximum age before oracle data is considered stale (10 minutes)
const max_oracle_age: Int = 600_000

// =============================================================================
// SECTION: Main Validator
// =============================================================================

validator oracle(params: OracleParams) {
  spend(
    datum_opt: Option<OracleData>,
    redeemer: OracleRedeemer,
    own_ref: OutputReference,
    ctx: ScriptContext,
  ) {
    expect Some(old_datum) = datum_opt
    let tx = ctx.transaction
    let own_input = find_own_input(tx.inputs, own_ref)
    when redeemer is {
      UpdatePrice { new_price, new_timestamp } -> {
        expect new_price > min_price
        expect new_timestamp > 0
        validate_price_update(
          old_datum,
          new_price,
          new_timestamp,
          params,
          own_input,
          tx,
        )
        True
      }
    }
  }

  else(_) {
    fail
  }
}

// =============================================================================
// SECTION: Validation Functions
// =============================================================================

/// Comprehensive validation of a price update request.
/// Checks: authorization, update frequency, price sanity, timestamp validity,
/// and output datum correctness.
fn validate_price_update(
  old_datum: OracleData,
  new_price: Int,
  new_timestamp: Int,
  params: OracleParams,
  own_input: Input,
  tx: Transaction,
) -> Void {
  // Verify the updater is authorized
  let is_authorized = check_authorized_signer(tx, params.authorized_updaters)
  expect is_authorized

  // Find the oracle output at the same address
  expect Some(oracle_output) =
    list.find(
      tx.outputs,
      fn(output) { output.address == own_input.output.address },
    )
  expect InlineDatum(new_datum_data) = oracle_output.datum
  expect new_datum: OracleData = new_datum_data

  // Verify update frequency constraint
  let time_check =
    check_update_frequency(
      old_datum.timestamp,
      new_timestamp,
      params.min_update_interval,
    )
  expect time_check

  // Verify price change is within allowed bounds
  let price_reasonable =
    validate_price_sanity(old_datum.price, new_price, params.max_price_change)
  expect price_reasonable

  // Verify timestamp falls within the transaction's validity range
  let timestamp_in_range = check_timestamp_in_tx_range(tx, new_timestamp)
  expect timestamp_in_range

  // Verify output datum matches the declared update values
  expect new_datum.source == old_datum.source
  expect new_datum.price == new_price
  expect new_datum.timestamp == new_timestamp
}

/// Check that at least one authorized updater has signed the transaction.
fn check_authorized_signer(tx: Transaction, authorized: List<ByteArray>) -> Bool {
  list.any(tx.extra_signatories, fn(sig) { list.has(authorized, sig) })
}

/// Enforce minimum time interval between price updates.
fn check_update_frequency(
  old_timestamp: Int,
  new_timestamp: Int,
  min_frequency: Int,
) -> Bool {
  new_timestamp - old_timestamp >= min_frequency
}

/// Validate that the price change is within allowed bounds (in basis points).
/// Prevents sudden extreme price swings that could indicate oracle manipulation.
fn validate_price_sanity(
  old_price: Int,
  new_price: Int,
  max_change_bps: Int,
) -> Bool {
  let max_change = old_price * max_change_bps / 10000
  let diff =
    if new_price > old_price {
      new_price - old_price
    } else {
      old_price - new_price
    }
  diff <= max_change
}

/// Verify that the new timestamp falls within the transaction's validity range.
/// This prevents oracle operators from backdating or postdating updates.
fn check_timestamp_in_tx_range(tx: Transaction, datum_timestamp: Int) -> Bool {
  when tx.validity_range.lower_bound.bound_type is {
    Finite(lower) ->
      when tx.validity_range.upper_bound.bound_type is {
        Finite(upper) -> datum_timestamp >= lower && datum_timestamp <= upper
        _ -> datum_timestamp >= lower
      }
    _ -> False
  }
}

// =============================================================================
// SECTION: Utility Functions (Public - Used by Other Validators)
// =============================================================================

/// Find the oracle's own input by matching the output reference.
fn find_own_input(inputs: List<Input>, ref: OutputReference) -> Input {
  expect Some(input) =
    list.find(inputs, fn(input) { input.output_reference == ref })
  input
}

/// Retrieve just the price from an oracle reference input.
pub fn get_oracle_price(oracle_ref: OutputReference, tx: Transaction) -> Int {
  expect Some(oracle_input) =
    list.find(
      tx.reference_inputs,
      fn(input) { input.output_reference == oracle_ref },
    )
  expect InlineDatum(datum_data) = oracle_input.output.datum
  expect oracle_datum: OracleData = datum_data
  oracle_datum.price
}

/// Retrieve full oracle data from a reference input.
pub fn get_oracle_data(
  oracle_ref: OutputReference,
  tx: Transaction,
) -> OracleData {
  expect Some(oracle_input) =
    list.find(
      tx.reference_inputs,
      fn(input) { input.output_reference == oracle_ref },
    )
  expect InlineDatum(datum_data) = oracle_input.output.datum
  expect oracle_datum: OracleData = datum_data
  oracle_datum
}

/// Check if oracle data is fresh (within max_oracle_age).
pub fn is_oracle_fresh(oracle_datum: OracleData, current_time: Int) -> Bool {
  let age = current_time - oracle_datum.timestamp
  age <= max_oracle_age
}

// =============================================================================
// SECTION: Multi-Oracle Aggregation
// =============================================================================

/// Aggregate prices from multiple oracle reference inputs using median.
/// Median is more resistant to outliers and oracle manipulation than average.
pub fn aggregate_oracle_prices(
  oracle_refs: List<OutputReference>,
  tx: Transaction,
) -> Int {
  let prices = list.map(oracle_refs, fn(ref) { get_oracle_price(ref, tx) })
  calculate_median(prices)
}

/// Calculate the median value of a list of prices.
/// - Odd count: returns the middle element
/// - Even count: returns the average of the two middle elements
/// - Empty list: fails with an error
fn calculate_median(prices: List<Int>) -> Int {
  let len = list.length(prices)

  if len == 0 {
    fail @"Cannot calculate median of empty price list"
  } else {
    let sorted_prices = sort_ascending(prices)

    if len % 2 == 1 {
      // Odd: take middle element (e.g., [1,2,3,4,5] -> 3)
      let middle_idx = len / 2
      expect Some(median) = list.at(sorted_prices, middle_idx)
      median
    } else {
      // Even: average of two middle elements (e.g., [1,2,3,4] -> 2)
      let mid1_idx = len / 2 - 1
      let mid2_idx = len / 2
      expect Some(mid1) = list.at(sorted_prices, mid1_idx)
      expect Some(mid2) = list.at(sorted_prices, mid2_idx)
      (mid1 + mid2) / 2
    }
  }
}

/// Sort a list of integers in ascending order using insertion sort.
/// Efficient for small lists (< 20 elements) typical of oracle feeds.
fn sort_ascending(prices: List<Int>) -> List<Int> {
  list.foldl(
    prices,
    [],
    fn(price, sorted) { insert_sorted(price, sorted) }
  )
}

/// Insert an element into a sorted list while maintaining order.
fn insert_sorted(value: Int, sorted_list: List<Int>) -> List<Int> {
  when sorted_list is {
    [] -> [value]
    [head, ..tail] ->
      if value <= head {
        [value, ..sorted_list]
      } else {
        [head, ..insert_sorted(value, tail)]
      }
  }
}
