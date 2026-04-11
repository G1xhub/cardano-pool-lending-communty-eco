// Cardano Lending Protocol - Position Validator
// Developed by grae.one (utxotools.io)
//
// Version: 8.0.0 - Registry Pattern Compatible
// License: Apache-2.0
//
// Manages individual borrower positions. Each borrower has a unique UTxO
// at this script address, identified by their position NFT. Positions track
// deposits, borrows, collateral, and interest accrual.
//
// This validator is stateless - it validates operations based on:
// 1. Owner signature verification
// 2. Pool input presence (ensures pool contract is involved)
// 3. Position NFT integrity (minted/burned correctly)

use aiken/collection/list
use lending/helpers.{find_own_input, get_current_time, script_address}
use lending/types.{
  Close, PositionDatum, PositionRedeemer, RepayPosition, UpdateBorrow,
  UpdateDeposit,
}
use cardano/address.{Address}
use cardano/assets.{PolicyId, flatten, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}

// =============================================================================
// SECTION: Main Validator
// =============================================================================
//
// No parameters needed - the position validator is fully stateless.
// It validates based on owner signature, pool input presence, and NFT handling.

validator position {
  spend(
    datum_opt: Option<PositionDatum>,
    redeemer: PositionRedeemer,
    own_ref: OutputReference,
    ctx: ScriptContext,
  ) {
    expect Some(datum) = datum_opt
    let tx = ctx.transaction
    let own_input = find_own_input(tx.inputs, own_ref)
    let position_token_policy = get_position_token_policy(own_input)

    when redeemer is {

      // =========================================================================
      // UPDATE DEPOSIT: Change the deposited amount (increase or decrease)
      // =========================================================================
      UpdateDeposit { amount_change, pool_ref } -> {
        expect amount_change != 0
        validate_update_deposit(
          datum,
          amount_change,
          pool_ref,
          own_input,
          tx,
          position_token_policy,
        )

        // Verify deposit amount changed in the expected direction
        expect Some(pos_output) =
          list.find(
            tx.outputs,
            fn(output) { output.address == own_input.output.address },
          )
        expect InlineDatum(new_datum_data) = pos_output.datum
        expect new_datum: PositionDatum = new_datum_data
        when amount_change > 0 is {
          True -> new_datum.deposited > datum.deposited
          False -> new_datum.deposited < datum.deposited
        }
      }

      // =========================================================================
      // UPDATE BORROW: Change borrow amount and/or collateral
      // =========================================================================
      UpdateBorrow { amount_change, collateral_change, pool_ref } -> {
        expect amount_change != 0 || collateral_change != 0
        validate_update_borrow(
          datum,
          amount_change,
          collateral_change,
          pool_ref,
          own_input,
          tx,
          position_token_policy,
        )

        // Verify borrow or collateral changed
        expect Some(pos_output) =
          list.find(
            tx.outputs,
            fn(output) { output.address == own_input.output.address },
          )
        expect InlineDatum(new_datum_data) = pos_output.datum
        expect new_datum: PositionDatum = new_datum_data
        when amount_change != 0 is {
          True -> new_datum.borrowed != datum.borrowed
          False -> new_datum.collateral != datum.collateral
        }
      }

      // =========================================================================
      // REPAY POSITION: Repay borrowed amount, reducing debt
      // =========================================================================
      RepayPosition { amount, pool_ref } -> {
        expect amount > 0
        validate_repay(
          datum,
          amount,
          pool_ref,
          own_input,
          tx,
          position_token_policy,
        )

        // Verify: either position closed (token burned) or borrowed decreased
        let outputs_to_self =
          list.filter(
            tx.outputs,
            fn(output) { output.address == own_input.output.address },
          )
        when list.length(outputs_to_self) is {
          0 -> check_token_burned(tx, position_token_policy, datum.owner)
          1 -> {
            expect Some(pos_output) = list.head(outputs_to_self)
            expect InlineDatum(new_datum_data) = pos_output.datum
            expect new_datum: PositionDatum = new_datum_data
            new_datum.borrowed < datum.borrowed
          }
          _ -> False
        }
      }

      // =========================================================================
      // CLOSE POSITION: Close a debt-free position entirely
      // =========================================================================
      Close { pool_ref } -> {
        validate_close(datum, pool_ref, own_input, tx, position_token_policy)

        // Verify no remaining debt and position NFT burned
        datum.borrowed == 0 && check_token_burned(
          tx,
          position_token_policy,
          datum.owner,
        )
      }
    }
  }

  else(_) {
    fail
  }
}

// =============================================================================
// SECTION: Helper Functions
// =============================================================================

/// Extract the position NFT policy from the position UTxO's tokens.
/// Identifies the unique NFT (quantity == 1) with a non-empty policy ID.
fn get_position_token_policy(own_input: Input) -> PolicyId {
  let tokens = flatten(own_input.output.value)
  expect Some((policy_id, _name, qty)) =
    list.find(
      tokens,
      fn(asset) {
        let (policy, _n, quantity) = asset
        policy != "" && quantity == 1
      },
    )
  policy_id
}

/// Verify that the pool input is present in the transaction.
/// This ensures the lending pool contract is involved in the operation.
fn has_pool_input(tx: Transaction, pool_ref: OutputReference) -> Bool {
  list.any(tx.inputs, fn(input) { input.output_reference == pool_ref })
}

/// Verify that the position NFT is preserved between input and output
/// (present with quantity == 1 in both).
fn check_position_token(
  input: Input,
  output: Output,
  policy_id: PolicyId,
  owner: ByteArray,
) -> Bool {
  let input_qty = quantity_of(input.output.value, policy_id, owner)
  let output_qty = quantity_of(output.value, policy_id, owner)
  input_qty == 1 && output_qty == 1
}

/// Check that the position NFT was burned (minted quantity == -1).
fn check_token_burned(
  tx: Transaction,
  policy_id: PolicyId,
  owner: ByteArray,
) -> Bool {
  let minted_qty = quantity_of(tx.mint, policy_id, owner)
  minted_qty == -1
}

// =============================================================================
// SECTION: Validation Functions
// =============================================================================

/// Validate a deposit update: owner signature, output datum integrity,
/// pool involvement, and NFT preservation.
fn validate_update_deposit(
  old_datum: PositionDatum,
  amount_change: Int,
  pool_ref: OutputReference,
  own_input: Input,
  tx: Transaction,
  policy_id: PolicyId,
) -> Void {
  let owner_signed = list.has(tx.extra_signatories, old_datum.owner)
  expect owner_signed

  expect Some(pos_output) =
    list.find(
      tx.outputs,
      fn(output) { output.address == own_input.output.address },
    )
  expect InlineDatum(new_datum_data) = pos_output.datum
  expect new_datum: PositionDatum = new_datum_data

  // Verify new deposit amount is non-negative
  let new_deposited = old_datum.deposited + amount_change
  expect new_deposited >= 0

  // Verify datum integrity
  expect new_datum.deposited == new_deposited
  expect new_datum.borrowed == old_datum.borrowed
  expect new_datum.collateral == old_datum.collateral
  expect new_datum.owner == old_datum.owner

  // Verify pool is involved in this transaction
  expect has_pool_input(tx, pool_ref)

  // Verify position NFT is preserved
  expect check_position_token(own_input, pos_output, policy_id, old_datum.owner)
}

/// Validate a borrow/collateral update: owner signature, output datum integrity,
/// non-negative amounts, pool involvement, and NFT preservation.
fn validate_update_borrow(
  old_datum: PositionDatum,
  amount_change: Int,
  collateral_change: Int,
  pool_ref: OutputReference,
  own_input: Input,
  tx: Transaction,
  policy_id: PolicyId,
) -> Void {
  let owner_signed = list.has(tx.extra_signatories, old_datum.owner)
  expect owner_signed

  expect Some(pos_output) =
    list.find(
      tx.outputs,
      fn(output) { output.address == own_input.output.address },
    )
  expect InlineDatum(new_datum_data) = pos_output.datum
  expect new_datum: PositionDatum = new_datum_data

  // Verify new amounts are non-negative
  let new_borrowed = old_datum.borrowed + amount_change
  let new_collateral = old_datum.collateral + collateral_change
  expect new_borrowed >= 0
  expect new_collateral >= 0

  // Verify datum integrity
  expect new_datum.borrowed == new_borrowed
  expect new_datum.collateral == new_collateral
  expect new_datum.deposited == old_datum.deposited

  // Verify pool is involved in this transaction
  expect has_pool_input(tx, pool_ref)

  // Verify position NFT is preserved
  expect check_position_token(own_input, pos_output, policy_id, old_datum.owner)
}

/// Validate a repayment: owner signature, pool involvement,
/// and correct output handling (position continues or closes).
fn validate_repay(
  old_datum: PositionDatum,
  amount: Int,
  pool_ref: OutputReference,
  own_input: Input,
  tx: Transaction,
  policy_id: PolicyId,
) -> Void {
  let owner_signed = list.has(tx.extra_signatories, old_datum.owner)
  expect owner_signed
  expect has_pool_input(tx, pool_ref)

  let outputs_to_self =
    list.filter(
      tx.outputs,
      fn(output) { output.address == own_input.output.address },
    )
  when list.length(outputs_to_self) is {
    // Position fully closed (no output to position address)
    0 -> {
      expect check_token_burned(tx, policy_id, old_datum.owner)
    }
    // Position continues with reduced debt
    1 -> {
      expect Some(pos_output) = list.head(outputs_to_self)
      expect InlineDatum(new_datum_data) = pos_output.datum
      expect new_datum: PositionDatum = new_datum_data
      // Borrowed must decrease
      expect new_datum.borrowed < old_datum.borrowed
      // Owner unchanged
      expect new_datum.owner == old_datum.owner
      // Collateral can decrease (released proportionally)
      expect new_datum.collateral <= old_datum.collateral
      // Position NFT preserved
      expect
        check_position_token(own_input, pos_output, policy_id, old_datum.owner)
    }
    // Invalid: multiple outputs to same address
    _ -> fail @"Invalid number of outputs to position address"
  }
}

/// Validate closing a position: owner signature, no remaining debt,
/// NFT burned, and pool involvement.
fn validate_close(
  old_datum: PositionDatum,
  pool_ref: OutputReference,
  own_input: Input,
  tx: Transaction,
  policy_id: PolicyId,
) -> Void {
  let owner_signed = list.has(tx.extra_signatories, old_datum.owner)
  expect owner_signed
  let no_debt = old_datum.borrowed == 0
  expect no_debt
  expect check_token_burned(tx, policy_id, old_datum.owner)
  expect has_pool_input(tx, pool_ref)
}
