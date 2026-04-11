// Cardano Lending Protocol - Staking Validator
// Developed by grae.one (utxotools.io)
//
// Version: 8.0.0 - Registry Pattern Migration
// License: Apache-2.0
//
// Manages the staking of governance tokens. Stakers earn ADA and
// governance token rewards proportional to their stake. The staking token policy
// is verified against the Registry to prevent unauthorized token manipulation.

use aiken/collection/list
use lending/helpers.{
  find_output_at_address, find_own_input, get_current_time, get_safe_current_time,
  get_minting_policy_or_from_inputs, is_signed_by, script_address,
  time_elapsed_at_least,
}
use lending/registry_helpers.{load_registry}
use lending/types.{
  AssetClass, ClaimRewards, ClaimRewardsOp, DistributeRewards, Operation,
  RegistryDatum, Stake, StakerPosition, StakingConfig, StakingDatum, StakingOp,
  StakingRedeemer, Unstake, Unstaking,
}
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, flatten, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}

// =============================================================================
// SECTION: Validator Parameters
// =============================================================================

/// The staking validator only requires the registry script hash.
/// The governance token policy and other configuration is loaded from the Registry.
pub type StakingParams {
  registry_script_hash: ByteArray,
}

// =============================================================================
// SECTION: Main Validator
// =============================================================================

validator staking(params: StakingParams) {
  spend(
    datum_opt: Option<StakingDatum>,
    redeemer: StakingRedeemer,
    own_ref: OutputReference,
    ctx: ScriptContext,
  ) {
    expect Some(datum) = datum_opt
    let tx = ctx.transaction
    let own_input = find_own_input(tx.inputs, own_ref)

    // Load protocol configuration from Registry
    let registry =
      load_registry(tx.reference_inputs, params.registry_script_hash)

    // Emergency shutdown check
    expect !registry.emergency_shutdown

    // SECURITY: Get governance token policy from the immutable Registry
    // (prevents manipulation via mutable datum fields)
    let staking_token_policy_val = registry.staking_token_policy
    let staking_token_name_val = registry.staking_token_name

    // Defense in depth: verify datum config matches registry
    expect datum.config.staking_token.policy_id == staking_token_policy_val
    expect datum.config.staking_token.asset_name == staking_token_name_val

    when redeemer is {

      // =========================================================================
      // STAKE: Lock governance tokens to earn rewards
      // =========================================================================
      Stake { amount } -> {
        expect !list.has(registry.paused_operations, StakingOp)
        expect amount > 0
        expect amount >= registry.min_deposit_amount
        expect amount <= registry.max_single_deposit

        validate_stake(
          datum,
          amount,
          own_input,
          tx,
          registry.position_hash,
          staking_token_policy_val,
          staking_token_name_val,
          registry,
        )

        // Verify the staking contract received the governance tokens
        expect Some(staking_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        expect InlineDatum(new_datum_data) = staking_output.datum
        expect new_datum: StakingDatum = new_datum_data
        let old_staking_token =
          quantity_of(own_input.output.value, staking_token_policy_val, staking_token_name_val)
        let new_staking_token =
          quantity_of(staking_output.value, staking_token_policy_val, staking_token_name_val)
        expect new_staking_token >= old_staking_token + amount

        True
      }

      // =========================================================================
      // UNSTAKE: Withdraw staked governance tokens (after min stake period)
      // =========================================================================
      Unstake { amount } -> {
        expect !list.has(registry.paused_operations, Unstaking)
        expect amount > 0

        validate_unstake(
          datum,
          amount,
          own_input,
          tx,
          registry.position_hash,
          staking_token_policy_val,
          staking_token_name_val,
        )

        // Verify the staking contract released the governance tokens
        expect Some(staking_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        expect InlineDatum(new_datum_data) = staking_output.datum
        expect new_datum: StakingDatum = new_datum_data
        let old_staking_token =
          quantity_of(own_input.output.value, staking_token_policy_val, staking_token_name_val)
        let new_staking_token =
          quantity_of(staking_output.value, staking_token_policy_val, staking_token_name_val)
        expect new_staking_token <= old_staking_token - amount

        True
      }

      // =========================================================================
      // CLAIM REWARDS: Withdraw accumulated ADA and governance token rewards
      // =========================================================================
      ClaimRewards -> {
        expect !list.has(registry.paused_operations, ClaimRewardsOp)

        validate_claim_rewards(
          datum,
          own_input,
          tx,
          registry.position_hash,
          staking_token_policy_val,
          staking_token_name_val,
        )

        // Verify that reward payment outputs exist
        expect Some(user_pkh) = list.head(tx.extra_signatories)
        list.any(
          tx.outputs,
          fn(output) {
            quantity_of(output.value, "", "") > 0 || quantity_of(
              output.value,
              staking_token_policy_val,
              staking_token_name_val,
            ) > 0
          },
        )
      }

      // =========================================================================
      // DISTRIBUTE REWARDS: Add new rewards to the staking pool
      // =========================================================================
      DistributeRewards { ada_amount, reward_amount } -> {
        expect ada_amount >= 0
        expect reward_amount >= 0
        expect ada_amount > 0 || reward_amount > 0

        validate_distribute_rewards(
          datum,
          ada_amount,
          reward_amount,
          own_input,
          tx,
          registry.treasury_hash,
          registry.lending_pool_hash,
          staking_token_policy_val,
          staking_token_name_val,
        )

        // Verify the rewards pool increased correctly
        expect Some(staking_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        expect InlineDatum(new_datum_data) = staking_output.datum
        expect new_datum: StakingDatum = new_datum_data
        expect new_datum.ada_rewards_pool >= datum.ada_rewards_pool + ada_amount && new_datum.staking_rewards_pool >= datum.staking_rewards_pool + reward_amount

        True
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

/// Create a staking token AssetClass from policy ID and asset name.
fn staking_token_asset(policy_id: PolicyId, asset_name: ByteArray) -> AssetClass {
  AssetClass { policy_id, asset_name }
}

/// Create an ADA AssetClass (empty policy_id and asset_name).
fn ada_asset() -> AssetClass {
  AssetClass { policy_id: "", asset_name: "" }
}

/// Extract the staker position NFT policy from the transaction.
/// First tries the mint field, then falls back to finding a unique NFT
/// in the first transaction input.
fn get_staker_token_policy_or_from_inputs(tx: Transaction) -> PolicyId {
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

/// Find a staker position input by matching the user's PKH and NFT policy.
fn find_staker_position(
  tx: Transaction,
  user_pkh: ByteArray,
  policy_id: PolicyId,
) -> Option<Input> {
  list.find(
    tx.inputs,
    fn(input) { quantity_of(input.output.value, policy_id, user_pkh) > 0 },
  )
}

// =============================================================================
// SECTION: Stake Validation
// =============================================================================

/// Validate a stake operation: verify staking tokens transferred, datum integrity,
/// user signature, and staker position correctness.
fn validate_stake(
  old_datum: StakingDatum,
  amount: Int,
  own_input: Input,
  tx: Transaction,
  staker_position_script_hash: ByteArray,
  staking_token_policy_val: PolicyId,
  staking_token_name_val: ByteArray,
  registry: RegistryDatum,
) -> Void {
  expect Some(staking_output) =
    find_output_at_address(tx.outputs, own_input.output.address)
  expect InlineDatum(new_datum_data) = staking_output.datum
  expect new_datum: StakingDatum = new_datum_data

  // Verify staking token transfer
  let old_staking_token = quantity_of(own_input.output.value, staking_token_policy_val, staking_token_name_val)
  let new_staking_token = quantity_of(staking_output.value, staking_token_policy_val, staking_token_name_val)
  expect new_staking_token == old_staking_token + amount

  // Verify datum integrity
  expect new_datum.total_staked == old_datum.total_staked + amount
  expect new_datum.ada_rewards_pool == old_datum.ada_rewards_pool
  expect new_datum.staking_rewards_pool == old_datum.staking_rewards_pool
  expect new_datum.config.min_stake_period == old_datum.config.min_stake_period

  // Verify user signature
  expect Some(user_pkh) = list.head(tx.extra_signatories)
  expect is_signed_by(tx, user_pkh)

  validate_staker_position_for_stake(
    tx,
    user_pkh,
    amount,
    staker_position_script_hash,
    registry,
  )
}

/// Validate the staker position output after staking.
fn validate_staker_position_for_stake(
  tx: Transaction,
  user_pkh: ByteArray,
  stake_amount: Int,
  staker_position_script_hash: ByteArray,
  registry: RegistryDatum,
) -> Void {
  let position_address = script_address(staker_position_script_hash)
  expect Some(position_output) =
    find_output_at_address(tx.outputs, position_address)
  expect InlineDatum(position_data) = position_output.datum
  expect position: StakerPosition = position_data
  let current_time = get_current_time(tx)
  expect position.owner == user_pkh
  expect position.staked_amount >= stake_amount
  expect position.stake_timestamp <= current_time

  // SECURITY: Verify Position NFT using registry-verified policy
  let position_nft_policy = registry.staker_nft_policy
  expect quantity_of(position_output.value, position_nft_policy, user_pkh) == 1
}

// =============================================================================
// SECTION: Unstake Validation
// =============================================================================

/// Validate an unstake operation: verify minimum stake period, user signature,
/// staking token release, and staker position correctness.
fn validate_unstake(
  old_datum: StakingDatum,
  amount: Int,
  own_input: Input,
  tx: Transaction,
  staker_position_script_hash: ByteArray,
  staking_token_policy_val: PolicyId,
  staking_token_name_val: ByteArray,
) -> Void {
  expect Some(user_pkh) = list.head(tx.extra_signatories)
  let staker_token_policy = get_staker_token_policy_or_from_inputs(tx)
  expect Some(position_input) =
    find_staker_position(tx, user_pkh, staker_token_policy)
  expect InlineDatum(position_data) = position_input.output.datum
  expect position: StakerPosition = position_data

  // Enforce minimum stake period
  expect
    time_elapsed_at_least(
      tx,
      position.stake_timestamp,
      old_datum.config.min_stake_period,
    )
  expect amount <= position.staked_amount

  expect Some(staking_output) =
    find_output_at_address(tx.outputs, own_input.output.address)
  expect InlineDatum(new_datum_data) = staking_output.datum
  expect new_datum: StakingDatum = new_datum_data

  // Verify staking token release
  let old_staking_token = quantity_of(own_input.output.value, staking_token_policy_val, staking_token_name_val)
  let new_staking_token = quantity_of(staking_output.value, staking_token_policy_val, staking_token_name_val)
  expect new_staking_token == old_staking_token - amount
  expect new_datum.total_staked == old_datum.total_staked - amount

  validate_staker_position_for_unstake(
    tx,
    position,
    amount,
    user_pkh,
    staker_position_script_hash,
    staker_token_policy,
  )
  expect is_signed_by(tx, user_pkh)
}

/// Validate staker position output after unstaking.
/// If full unstake, the position NFT must be burned.
fn validate_staker_position_for_unstake(
  tx: Transaction,
  old_position: StakerPosition,
  unstake_amount: Int,
  user_pkh: ByteArray,
  staker_position_script_hash: ByteArray,
  policy_id: PolicyId,
) -> Void {
  if unstake_amount >= old_position.staked_amount {
    // Full unstake: position NFT must be burned
    let burned = quantity_of(tx.mint, policy_id, user_pkh) == -1
    expect burned
  } else {
    // Partial unstake: verify position datum
    let position_address = script_address(staker_position_script_hash)
    expect Some(position_output) =
      find_output_at_address(tx.outputs, position_address)
    expect InlineDatum(new_position_data) = position_output.datum
    expect new_position: StakerPosition = new_position_data
    expect
      new_position.staked_amount == old_position.staked_amount - unstake_amount
    expect new_position.owner == old_position.owner
  }
}

// =============================================================================
// SECTION: Claim Rewards Validation
// =============================================================================

/// Validate a reward claim: calculate pending rewards, verify payment,
/// update staking datum, and update staker position.
fn validate_claim_rewards(
  old_datum: StakingDatum,
  own_input: Input,
  tx: Transaction,
  staker_position_script_hash: ByteArray,
  staking_token_policy_val: PolicyId,
  staking_token_name_val: ByteArray,
) -> Void {
  expect Some(user_pkh) = list.head(tx.extra_signatories)
  let staker_token_policy = get_staker_token_policy_or_from_inputs(tx)
  expect Some(position_input) =
    find_staker_position(tx, user_pkh, staker_token_policy)
  expect InlineDatum(position_data) = position_input.output.datum
  expect position: StakerPosition = position_data

  let (ada_rewards, staking_token_rewards) = calculate_user_rewards(position, old_datum)

  expect
    validate_reward_payment(
      tx,
      user_pkh,
      ada_rewards,
      staking_token_rewards,
      staking_token_policy_val,
      staking_token_name_val,
    )

  // Verify staking datum updates
  expect Some(staking_output) =
    find_output_at_address(tx.outputs, own_input.output.address)
  expect InlineDatum(new_datum_data) = staking_output.datum
  expect new_datum: StakingDatum = new_datum_data
  expect new_datum.ada_rewards_pool == old_datum.ada_rewards_pool - ada_rewards
  expect
    new_datum.staking_rewards_pool == old_datum.staking_rewards_pool - staking_token_rewards

  validate_position_after_claim(
    tx,
    position,
    ada_rewards,
    staking_token_rewards,
    staker_position_script_hash,
  )
  expect is_signed_by(tx, user_pkh)
}

/// Calculate the pending rewards for a staker based on their share of the pool.
///
/// Formula: user_share = staked_amount * 10000 / total_staked
///          rewards = rewards_pool * user_share / 10000 - already_claimed
///
/// Returns (ada_rewards, staking_token_rewards). Clamps negative values to 0.
fn calculate_user_rewards(
  position: StakerPosition,
  staking_datum: StakingDatum,
) -> (Int, Int) {
  if staking_datum.total_staked == 0 {
    (0, 0)
  } else {
    let user_share = position.staked_amount * 10000 / staking_datum.total_staked
    let ada_rewards = staking_datum.ada_rewards_pool * user_share / 10000
    let staking_token_rewards = staking_datum.staking_rewards_pool * user_share / 10000
    let unclaimed_ada = ada_rewards - position.ada_rewards_claimed
    let unclaimed_staking_token = staking_token_rewards - position.staking_rewards_claimed
    let final_ada =
      if unclaimed_ada < 0 {
        0
      } else {
        unclaimed_ada
      }
    let final_staking_token =
      if unclaimed_staking_token < 0 {
        0
      } else {
        unclaimed_staking_token
      }
    (final_ada, final_staking_token)
  }
}

/// Verify that a reward payment output exists with sufficient ADA and staking tokens.
fn validate_reward_payment(
  tx: Transaction,
  user_pkh: ByteArray,
  ada_rewards: Int,
  staking_token_rewards: Int,
  staking_token_policy_val: PolicyId,
  staking_token_name_val: ByteArray,
) -> Bool {
  list.any(
    tx.outputs,
    fn(output) {
      let has_ada = quantity_of(output.value, "", "") >= ada_rewards
      let has_staking_token =
        quantity_of(output.value, staking_token_policy_val, staking_token_name_val) >= staking_token_rewards
      has_ada && has_staking_token
    },
  )
}

/// Verify the staker position datum is updated correctly after a claim.
fn validate_position_after_claim(
  tx: Transaction,
  old_position: StakerPosition,
  ada_claimed: Int,
  staking_token_claimed: Int,
  staker_position_script_hash: ByteArray,
) -> Void {
  let position_address = script_address(staker_position_script_hash)
  expect Some(position_output) =
    find_output_at_address(tx.outputs, position_address)
  expect InlineDatum(new_position_data) = position_output.datum
  expect new_position: StakerPosition = new_position_data
  expect
    new_position.ada_rewards_claimed == old_position.ada_rewards_claimed + ada_claimed
  expect
    new_position.staking_rewards_claimed == old_position.staking_rewards_claimed + staking_token_claimed
  expect new_position.staked_amount == old_position.staked_amount
}

// =============================================================================
// SECTION: Distribute Rewards Validation
// =============================================================================

/// Validate that rewards are distributed from an authorized source
/// (treasury or lending pool) and that the staking datum is updated correctly.
fn validate_distribute_rewards(
  old_datum: StakingDatum,
  ada_amount: Int,
  reward_amount: Int,
  own_input: Input,
  tx: Transaction,
  treasury_script_hash: ByteArray,
  lending_pool_script_hash: ByteArray,
  staking_token_policy_val: PolicyId,
  staking_token_name_val: ByteArray,
) -> Void {
  expect Some(staking_output) =
    find_output_at_address(tx.outputs, own_input.output.address)
  expect InlineDatum(new_datum_data) = staking_output.datum
  expect new_datum: StakingDatum = new_datum_data

  // Verify actual token transfers
  let old_ada = quantity_of(own_input.output.value, "", "")
  let new_ada = quantity_of(staking_output.value, "", "")
  expect new_ada == old_ada + ada_amount
  let old_staking_token = quantity_of(own_input.output.value, staking_token_policy_val, staking_token_name_val)
  let new_staking_token = quantity_of(staking_output.value, staking_token_policy_val, staking_token_name_val)
  expect new_staking_token == old_staking_token + reward_amount

  // Verify datum updates
  expect new_datum.ada_rewards_pool == old_datum.ada_rewards_pool + ada_amount
  expect
    new_datum.staking_rewards_pool == old_datum.staking_rewards_pool + reward_amount
  expect new_datum.total_staked == old_datum.total_staked

  // Verify rewards come from an authorized protocol contract
  expect
    is_from_authorized_source(
      tx,
      treasury_script_hash,
      lending_pool_script_hash,
    )

  // SECURITY: Use UPPER BOUND time (cannot be manipulated by user)
  let current_time = get_safe_current_time(tx)
  expect new_datum.last_reward_distribution == current_time
}

/// Check that at least one input comes from an authorized source
/// (either the treasury or the lending pool contract).
fn is_from_authorized_source(
  tx: Transaction,
  treasury_script_hash: ByteArray,
  lending_pool_script_hash: ByteArray,
) -> Bool {
  list.any(
    tx.inputs,
    fn(input) {
      when input.output.address.payment_credential is {
        Script(hash) ->
          hash == treasury_script_hash || hash == lending_pool_script_hash
        _ -> False
      }
    },
  )
}
