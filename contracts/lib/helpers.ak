// Cardano Lending Protocol - Helper Functions
// Developed by grae.one (utxotools.io)
//
// Version: 8.0.0 - Registry Pattern Compatible
// License: Apache-2.0
//
// Shared utility functions used across all validators. Includes:
// - Input/output lookup helpers
// - Address construction
// - Signature verification
// - Oracle data retrieval
// - Time utilities
// - Batcher system helpers
// - Bytearray/int conversion utilities
// - Script address validation

use aiken/builtin
use aiken/collection/list
use aiken/interval.{Finite}
use aiken/primitive/bytearray
use lending/types.{OracleData, PositionDatum}
use cardano/address.{Address, Script, VerificationKey, from_script}
use cardano/assets.{Value, flatten, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, ValidityRange,
}

// =============================================================================
// SECTION: Input/Output Lookup
// =============================================================================

/// Find the validator's own input being spent by matching the output reference.
/// Fails if the input cannot be found (should never happen in valid transactions).
pub fn find_own_input(inputs: List<Input>, own_ref: OutputReference) -> Input {
  expect Some(input) =
    list.find(inputs, fn(input) { input.output_reference == own_ref })
  input
}

/// Find the first transaction output sent to a specific address.
/// Returns None if no output matches the address.
pub fn find_output_at_address(
  outputs: List<Output>,
  addr: Address,
) -> Option<Output> {
  list.find(outputs, fn(output) { output.address == addr })
}

/// Find a transaction input by its output reference.
/// Returns None if no input matches the reference.
pub fn find_input_by_ref(
  inputs: List<Input>,
  ref: OutputReference,
) -> Option<Input> {
  list.find(inputs, fn(input) { input.output_reference == ref })
}

/// Find a position input by its output reference within a transaction.
/// Convenience wrapper around find_input_by_ref using tx.inputs.
pub fn find_position_by_ref(
  tx: Transaction,
  position_ref: OutputReference,
) -> Option<Input> {
  list.find(tx.inputs, fn(input) { input.output_reference == position_ref })
}

// =============================================================================
// SECTION: Address Construction
// =============================================================================

/// Construct a script Address from a script hash byte string.
pub fn script_address(script_hash: ByteArray) -> Address {
  from_script(script_hash)
}

// =============================================================================
// SECTION: Signature Verification
// =============================================================================

/// Check if a specific public key hash has signed the transaction.
pub fn is_signed_by(tx: Transaction, pkh: ByteArray) -> Bool {
  list.has(tx.extra_signatories, pkh)
}

/// Check if at least `required_duration` milliseconds have elapsed
/// since `start_time` based on the transaction's validity range.
pub fn time_elapsed_at_least(
  tx: Transaction,
  start_time: Int,
  required_duration: Int,
) -> Bool {
  let current_time = get_current_time(tx)
  current_time - start_time >= required_duration
}

// =============================================================================
// SECTION: Oracle Data Retrieval
// =============================================================================

/// Retrieve and parse oracle data from a reference input.
/// The oracle UTxO must be included in the transaction's reference_inputs.
pub fn get_oracle_data(
  tx: Transaction,
  oracle_ref: OutputReference,
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

/// Check if oracle data is fresh enough for general operations.
/// Uses a hardcoded 10-minute (600,000 ms) maximum age.
///
/// SECURITY NOTE: For borrow/liquidation operations, use the configurable
/// max_oracle_age from pool config instead of this hardcoded check.
pub fn is_oracle_fresh(oracle_data: OracleData, current_time: Int) -> Bool {
  let max_oracle_age = 600_000
  let age = current_time - oracle_data.timestamp
  age <= max_oracle_age
}

// =============================================================================
// SECTION: Position Datum Parsing
// =============================================================================

/// Parse a PositionDatum from a transaction output's inline datum.
/// Fails if the output has no inline datum or the datum type doesn't match.
pub fn parse_position_datum(output: Output) -> PositionDatum {
  expect InlineDatum(datum_data) = output.datum
  expect position: PositionDatum = datum_data
  position
}

// =============================================================================
// SECTION: Time Utilities
// =============================================================================

/// Get the current time from the transaction validity range's LOWER bound.
///
/// WARNING: The lower bound is set by the transaction author and can be
/// manipulated to represent a future time. Use get_safe_current_time()
/// (upper bound) for critical time-sensitive operations where user
/// manipulation of the timestamp could be exploited.
pub fn get_current_time(tx: Transaction) -> Int {
  when tx.validity_range.lower_bound.bound_type is {
    Finite(time) -> time
    _ -> fail @"Invalid time range: missing lower bound"
  }
}

/// Get a safe current time from the transaction validity range's UPPER bound.
///
/// SECURITY: The upper bound cannot be set to a future time by the user,
/// making this safer for reward distributions and other critical operations.
pub fn get_safe_current_time(tx: Transaction) -> Int {
  when tx.validity_range.upper_bound.bound_type is {
    Finite(time) -> time
    _ -> fail @"Invalid time range: missing upper bound"
  }
}

// =============================================================================
// SECTION: Minting Policy Helpers
// =============================================================================

/// Extract the minting policy ID from the transaction's minted value,
/// falling back to extracting a unique NFT from the first input.
///
/// Used to determine the position/staker NFT policy when validating
/// token minting/burning operations.
pub fn get_minting_policy_or_from_inputs(tx: Transaction) -> ByteArray {
  let from_mint = tx.mint |> flatten() |> list.head()
  when from_mint is {
    Some((policy_id, _name, _qty)) -> policy_id
    None -> {
      expect Some(input) = list.head(tx.inputs)
      expect Some((policy_id, _name, _qty)) =
        input.output.value
          |> flatten()
          |> list.find(
              fn(asset) {
                let (policy, _n, quantity) = asset
                policy != "" && quantity == 1
              },
            )
      policy_id
    }
  }
}

// =============================================================================
// SECTION: Batcher System Helpers
// =============================================================================

/// Extract the deadline from a batcher license token embedded in a Value.
///
/// Batcher licenses encode their expiration deadline as the token name
/// (bytearray representation of a Unix timestamp in milliseconds).
/// Returns None if no matching license token is found.
pub fn find_license_deadline(
  license_policy: ByteArray,
  value: Value,
) -> Option<Int> {
  let tokens = flatten(value)
  let license_token =
    list.find(
      tokens,
      fn(asset) {
        let (policy, _name, qty) = asset
        policy == license_policy && qty == 1
      },
    )
  when license_token is {
    Some((_policy, deadline_bytes, _qty)) ->
      Some(bytearray_to_int(deadline_bytes))
    None -> None
  }
}

/// Count the number of order inputs in the transaction that belong to
/// the orderbook script. Used to verify batch operation integrity.
pub fn count_orders(inputs: List<Input>, order_script_hash: ByteArray) -> Int {
  list.foldl(
    inputs,
    0,
    fn(input, acc) {
      when input.output.address.payment_credential is {
        Script(hash) ->
          if hash == order_script_hash {
            acc + 1
          } else {
            acc
          }
        _ -> acc
      }
    },
  )
}

/// Validate that a batcher license is valid and not expired.
///
/// Checks:
/// 1. The license input exists at the specified index
/// 2. The license token is present with the correct policy
/// 3. The license deadline has not yet passed
pub fn validate_batcher_license(
  tx: Transaction,
  license_input_idx: Int,
  license_policy: ByteArray,
  current_time: Int,
) -> Bool {
  expect Some(license_input) = list.at(tx.inputs, license_input_idx)
  expect Some(deadline) =
    find_license_deadline(license_policy, license_input.output.value)
  deadline >= current_time
}

// =============================================================================
// SECTION: Bytearray <-> Integer Conversion
// =============================================================================

/// Convert a decimal-encoded ByteArray to an Int.
///
/// Supports optional leading minus sign ('-' = ASCII 45).
/// Digit characters '0'-'9' are interpreted as their decimal values.
/// Fails on non-numeric characters.
pub fn bytearray_to_int(bytes: ByteArray) -> Int {
  bytearray_to_int_recursive(bytes, 0, bytearray.length(bytes), 0)
}

fn bytearray_to_int_recursive(
  bytes: ByteArray,
  idx: Int,
  len: Int,
  acc: Int,
) -> Int {
  if idx == len {
    acc
  } else {
    let byte = builtin.index_bytearray(bytes, idx)
    if idx == 0 && byte == 45 {
      // Leading minus sign ('-' = ASCII 45)
      -bytearray_to_int_recursive(bytes, idx + 1, len, 0)
    } else if byte >= 48 && byte <= 57 {
      // Digit character ('0'-'9' = ASCII 48-57)
      bytearray_to_int_recursive(bytes, idx + 1, len, acc * 10 + (byte - 48))
    } else {
      fail @"Invalid digit in bytearray"
    }
  }
}

/// Convert an Int to its decimal ByteArray representation.
/// Negative numbers are prefixed with '-' (ASCII 45).
pub fn int_to_bytearray(n: Int) -> ByteArray {
  if n == 0 {
    #"30" // ASCII '0'
  } else if n < 0 {
    bytearray.concat(#"2d", int_to_bytearray_positive(-n)) // '-' prefix
  } else {
    int_to_bytearray_positive(n)
  }
}

fn int_to_bytearray_positive(n: Int) -> ByteArray {
  if n == 0 {
    #""
  } else {
    let digit = n % 10
    let rest = n / 10
    let digit_byte = bytearray.push(#"", 48 + digit) // ASCII '0' = 48
    bytearray.concat(int_to_bytearray_positive(rest), digit_byte)
  }
}

// =============================================================================
// SECTION: Safe Input/Output Accessors
// =============================================================================

/// Safely access a transaction input by index. Returns None if out of bounds.
pub fn get_input_at(inputs: List<Input>, idx: Int) -> Option<Input> {
  list.at(inputs, idx)
}

/// Safely access a transaction output by index. Returns None if out of bounds.
pub fn get_output_at(outputs: List<Output>, idx: Int) -> Option<Output> {
  list.at(outputs, idx)
}

// =============================================================================
// SECTION: Script Address Validation
// =============================================================================

/// Check if a transaction input's address matches an expected script hash.
pub fn check_input_script(input: Input, expected_hash: ByteArray) -> Bool {
  when input.output.address.payment_credential is {
    Script(script_hash) -> script_hash == expected_hash
    _ -> False
  }
}

/// Check if a transaction output's address matches an expected script hash.
pub fn check_output_script(output: Output, expected_hash: ByteArray) -> Bool {
  when output.address.payment_credential is {
    Script(script_hash) -> script_hash == expected_hash
    _ -> False
  }
}

// =============================================================================
// SECTION: Address Validators
// =============================================================================

/// Validate that an address belongs to a specific public key hash.
pub fn validate_address(addr: Address, expected_pkh: ByteArray) -> Bool {
  when addr.payment_credential is {
    VerificationKey(pkh) -> pkh == expected_pkh
    _ -> False
  }
}

/// Validate that an address belongs to a specific script hash.
pub fn validate_script_address(addr: Address, expected_hash: ByteArray) -> Bool {
  when addr.payment_credential is {
    Script(hash) -> hash == expected_hash
    _ -> False
  }
}
