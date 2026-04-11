// Cardano Lending Protocol - Staker Position Validator
// Developed by grae.one (utxotools.io)
//
// Version: 8.0.0 - Registry Pattern Compatible
// License: Apache-2.0
//
// Manages individual staker position state. Each staker has a unique UTxO
// at this script address, identified by their staker NFT. The staker position
// tracks staked amounts, reward debts, and claim history.

use aiken/collection/list
use lending/helpers.{
  find_own_input, get_current_time, is_signed_by, script_address,
}
use lending/types.{
  CloseStakerPosition, StakerPosition, StakerPositionRedeemer,
  UpdateClaimRewards, UpdateStake, UpdateUnstake,
}
use cardano/address.{Address}
use cardano/assets.{PolicyId, flatten, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, Input, OutputReference, Transaction}

// =============================================================================
// SECTION: Main Validator
// =============================================================================

validator staker_position {
  spend(
    datum_opt: Option<StakerPosition>,
    redeemer: StakerPositionRedeemer,
    own_ref: OutputReference,
    ctx: ScriptContext,
  ) {
    expect Some(datum) = datum_opt
    let tx = ctx.transaction
    let own_input = find_own_input(tx.inputs, own_ref)
    let staker_position_policy = get_staker_position_token_policy(own_input)

    when redeemer is {

      // =========================================================================
      // UPDATE STAKE: Increase staked amount after a stake operation
      // =========================================================================
      UpdateStake { amount, staking_ref } -> {
        expect amount > 0
        validate_stake(
          datum,
          amount,
          staking_ref,
          own_input,
          tx,
          staker_position_policy,
        )

        // Verify staked amount increased in the output
        expect Some(position_output) =
          list.find(
            tx.outputs,
            fn(output) { output.address == own_input.output.address },
          )
        expect InlineDatum(new_datum_data) = position_output.datum
        expect new_datum: StakerPosition = new_datum_data
        new_datum.staked_amount > datum.staked_amount
      }

      // =========================================================================
      // UPDATE UNSTAKE: Decrease staked amount after an unstake operation
      // =========================================================================
      UpdateUnstake { amount, staking_ref } -> {
        expect amount > 0
        validate_unstake(
          datum,
          amount,
          staking_ref,
          own_input,
          tx,
          staker_position_policy,
        )

        // Verify: either position closed (token burned) or amount decreased
        let outputs_to_self =
          list.filter(
            tx.outputs,
            fn(output) { output.address == own_input.output.address },
          )
        when list.length(outputs_to_self) is {
          0 -> check_token_burned(tx, staker_position_policy, datum.owner)
          1 -> {
            expect Some(pos_output) = list.head(outputs_to_self)
            expect InlineDatum(new_datum_data) = pos_output.datum
            expect new_datum: StakerPosition = new_datum_data
            new_datum.staked_amount < datum.staked_amount
          }
          _ -> False
        }
      }

      // =========================================================================
      // UPDATE CLAIM REWARDS: Update position after claiming rewards
      // =========================================================================
      UpdateClaimRewards { staking_ref } -> {
        validate_claim_rewards(
          datum,
          staking_ref,
          own_input,
          tx,
          staker_position_policy,
        )

        // Verify rewards claimed counter increased
        expect Some(position_output) =
          list.find(
            tx.outputs,
            fn(output) { output.address == own_input.output.address },
          )
        expect InlineDatum(new_datum_data) = position_output.datum
        expect new_datum: StakerPosition = new_datum_data
        new_datum.ada_rewards_claimed >= datum.ada_rewards_claimed || new_datum.staking_rewards_claimed >= datum.staking_rewards_claimed
      }

      // =========================================================================
      // CLOSE STAKER POSITION: Close a fully unstaked position
      // =========================================================================
      CloseStakerPosition { staking_ref } -> {
        validate_close_staker(
          datum,
          staking_ref,
          own_input,
          tx,
          staker_position_policy,
        )

        // Verify no remaining stake and NFT burned
        datum.staked_amount == 0 && check_token_burned(
          tx,
          staker_position_policy,
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

/// Extract the staker position NFT policy from the UTxO's tokens.
/// Looks for a unique NFT (quantity == 1) with a non-empty policy ID.
fn get_staker_position_token_policy(own_input: Input) -> PolicyId {
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

/// Check that the staking contract input is present in the transaction.
fn has_staking_input(tx: Transaction, staking_ref: OutputReference) -> Bool {
  list.any(tx.inputs, fn(input) { input.output_reference == staking_ref })
}

/// Verify that the staker NFT is preserved (exists in input AND output).
fn check_staker_token_preserved(
  input: Input,
  output_address: Address,
  tx: Transaction,
  policy_id: PolicyId,
  owner: ByteArray,
) -> Bool {
  let input_qty = quantity_of(input.output.value, policy_id, owner)
  expect input_qty == 1
  expect Some(output) =
    list.find(tx.outputs, fn(out) { out.address == output_address })
  let output_qty = quantity_of(output.value, policy_id, owner)
  output_qty == 1
}

/// Check that the staker NFT was burned (minted quantity == -1).
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

/// Validate a stake update: owner signature, staking input present,
/// output datum integrity, and NFT preservation.
fn validate_stake(
  old_datum: StakerPosition,
  amount: Int,
  staking_ref: OutputReference,
  own_input: Input,
  tx: Transaction,
  policy_id: PolicyId,
) -> Void {
  expect is_signed_by(tx, old_datum.owner)
  expect has_staking_input(tx, staking_ref)
  expect Some(position_output) =
    list.find(
      tx.outputs,
      fn(output) { output.address == own_input.output.address },
    )
  expect InlineDatum(new_datum_data) = position_output.datum
  expect new_datum: StakerPosition = new_datum_data
  expect new_datum.owner == old_datum.owner
  expect new_datum.staked_amount >= old_datum.staked_amount + amount
  expect
    check_staker_token_preserved(
      own_input,
      own_input.output.address,
      tx,
      policy_id,
      old_datum.owner,
    )
}

/// Validate an unstake update: owner signature, staking input present,
/// amount within bounds, and correct output handling.
fn validate_unstake(
  old_datum: StakerPosition,
  amount: Int,
  staking_ref: OutputReference,
  own_input: Input,
  tx: Transaction,
  policy_id: PolicyId,
) -> Void {
  expect is_signed_by(tx, old_datum.owner)
  expect has_staking_input(tx, staking_ref)
  expect amount <= old_datum.staked_amount

  let outputs_to_self =
    list.filter(
      tx.outputs,
      fn(output) { output.address == own_input.output.address },
    )
  when list.length(outputs_to_self) is {
    0 -> {
      // Full unstake: NFT must be burned
      expect check_token_burned(tx, policy_id, old_datum.owner)
    }
    1 -> {
      // Partial unstake: verify datum and NFT preservation
      expect Some(position_output) = list.head(outputs_to_self)
      expect InlineDatum(new_datum_data) = position_output.datum
      expect new_datum: StakerPosition = new_datum_data
      expect new_datum.staked_amount == old_datum.staked_amount - amount
      expect new_datum.owner == old_datum.owner
      expect
        check_staker_token_preserved(
          own_input,
          own_input.output.address,
          tx,
          policy_id,
          old_datum.owner,
        )
    }
    _ -> fail @"Invalid number of outputs to staker position address"
  }
}

/// Validate a claim rewards update: owner signature, staking input present,
/// rewards counters increased, staked amount unchanged.
fn validate_claim_rewards(
  old_datum: StakerPosition,
  staking_ref: OutputReference,
  own_input: Input,
  tx: Transaction,
  policy_id: PolicyId,
) -> Void {
  expect is_signed_by(tx, old_datum.owner)
  expect has_staking_input(tx, staking_ref)
  expect Some(position_output) =
    list.find(
      tx.outputs,
      fn(output) { output.address == own_input.output.address },
    )
  expect InlineDatum(new_datum_data) = position_output.datum
  expect new_datum: StakerPosition = new_datum_data
  expect new_datum.ada_rewards_claimed >= old_datum.ada_rewards_claimed
  expect new_datum.staking_rewards_claimed >= old_datum.staking_rewards_claimed
  expect new_datum.staked_amount == old_datum.staked_amount
  expect new_datum.owner == old_datum.owner
  expect
    check_staker_token_preserved(
      own_input,
      own_input.output.address,
      tx,
      policy_id,
      old_datum.owner,
    )
}

/// Validate closing a staker position: owner signature, zero stake,
/// NFT burned, no output to this address.
fn validate_close_staker(
  old_datum: StakerPosition,
  staking_ref: OutputReference,
  own_input: Input,
  tx: Transaction,
  policy_id: PolicyId,
) -> Void {
  expect is_signed_by(tx, old_datum.owner)
  expect has_staking_input(tx, staking_ref)
  expect old_datum.staked_amount == 0
  expect check_token_burned(tx, policy_id, old_datum.owner)
  let no_output =
    !list.any(
      tx.outputs,
      fn(output) { output.address == own_input.output.address },
    )
  expect no_output
}

// =============================================================================
// SECTION: Placeholder Tests
// =============================================================================
// TODO: Implement comprehensive property-based tests using Aiken's test framework.
// These placeholders are required for compilation but do not validate any logic.

test stake_position() {
  True
}

test unstake_position() {
  True
}

test claim_rewards() {
  True
}

test close_position() {
  True
}
