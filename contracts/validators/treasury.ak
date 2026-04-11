// Cardano Lending Protocol - Treasury Validator
// Developed by grae.one (utxotools.io)
//
// Version: 8.0.0 - Registry Pattern Migration
// License: Apache-2.0
//
// Manages protocol fees and governance. The treasury collects fees from
// lending pool interest and liquidation penalties, then distributes them
// to LPs, stakers, and the protocol according to configured ratios.
//
// Governance operations require multi-signature approval from the configured
// governance keys with a minimum signature threshold.

use aiken/collection/list
use lending/helpers.{
  find_output_at_address, find_own_input, get_current_time, is_signed_by,
}
use lending/registry_helpers.{load_registry}
use lending/types.{
  AssetClass, CollectFees, ContractType, DistributeFees, FeeDistribution,
  FeeType, Pool, PoolDatum, RegistryDatum, Staking, StakingDatum, TreasuryDatum,
  TreasuryRedeemer, UpdateConfig, WithdrawProtocol,
}
use cardano/address.{Address, Script}
use cardano/assets.{PolicyId, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}

// =============================================================================
// SECTION: Validator Parameters
// =============================================================================

/// The treasury only requires the registry script hash.
/// All fee distribution ratios and contract addresses come from the Registry.
pub type TreasuryParams {
  registry_script_hash: ByteArray,
}

// =============================================================================
// SECTION: Main Validator
// =============================================================================

validator treasury(params: TreasuryParams) {
  spend(
    datum_opt: Option<TreasuryDatum>,
    redeemer: TreasuryRedeemer,
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

    when redeemer is {

      // =========================================================================
      // COLLECT FEES: Receive fees from pool or staking contracts
      // =========================================================================
      CollectFees { fee_type, amount, asset, from_contract } -> {
        expect amount > 0
        validate_collect_fees(
          datum,
          fee_type,
          amount,
          asset,
          from_contract,
          own_input,
          tx,
          registry,
        )

        // Verify treasury balance increased
        expect Some(treasury_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        let old_value =
          quantity_of(own_input.output.value, asset.policy_id, asset.asset_name)
        let new_value =
          quantity_of(treasury_output.value, asset.policy_id, asset.asset_name)
        expect new_value >= old_value + amount

        True
      }

      // =========================================================================
      // DISTRIBUTE FEES: Send collected fees to LPs, stakers, and protocol
      // =========================================================================
      DistributeFees { asset, amount_to_distribute } -> {
        expect amount_to_distribute > 0
        expect amount_to_distribute <= registry.max_single_deposit

        validate_distribute_fees(
          datum,
          asset,
          amount_to_distribute,
          own_input,
          tx,
          registry,
        )

        // Verify treasury balance decreased by the distributed amount
        expect Some(treasury_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        let old_value =
          quantity_of(own_input.output.value, asset.policy_id, asset.asset_name)
        let new_value =
          quantity_of(treasury_output.value, asset.policy_id, asset.asset_name)
        expect new_value <= old_value - amount_to_distribute

        True
      }

      // =========================================================================
      // UPDATE CONFIG: Change fee distribution ratios (multisig required)
      // =========================================================================
      UpdateConfig { new_distribution } -> {
        validate_update_config(datum, new_distribution, own_input, tx)

        // Verify distribution ratios sum to exactly 100%
        let ratios_sum =
          new_distribution.lp_ratio + new_distribution.staker_ratio + new_distribution.protocol_ratio
        expect ratios_sum == 10000

        True
      }

      // =========================================================================
      // WITHDRAW PROTOCOL: Withdraw protocol's share of fees (multisig required)
      // =========================================================================
      WithdrawProtocol { asset, amount } -> {
        expect amount > 0
        validate_withdraw_protocol(datum, asset, amount, own_input, tx)

        // Verify amount was actually withdrawn
        expect Some(treasury_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        let old_value =
          quantity_of(own_input.output.value, asset.policy_id, asset.asset_name)
        let new_value =
          quantity_of(treasury_output.value, asset.policy_id, asset.asset_name)
        expect new_value <= old_value - amount

        True
      }
    }
  }

  else(_) {
    fail
  }
}

// =============================================================================
// SECTION: Source Validation Helpers
// =============================================================================

/// Check that at least one transaction input comes from the lending pool.
fn validate_from_pool(tx: Transaction, registry: RegistryDatum) -> Bool {
  list.any(
    tx.inputs,
    fn(input) {
      when input.output.address.payment_credential is {
        Script(hash) -> hash == registry.lending_pool_hash
        _ -> False
      }
    },
  )
}

/// Check that at least one transaction input comes from the staking contract.
fn validate_from_staking(tx: Transaction, registry: RegistryDatum) -> Bool {
  list.any(
    tx.inputs,
    fn(input) {
      when input.output.address.payment_credential is {
        Script(hash) -> hash == registry.staking_hash
        _ -> False
      }
    },
  )
}

// =============================================================================
// SECTION: Output Discovery Helpers
// =============================================================================

/// Find a transaction output containing a PoolDatum.
/// Uses inline datum type checking to identify the pool output.
fn find_pool_output(tx: Transaction) -> Option<Output> {
  list.find(
    tx.outputs,
    fn(output) {
      when output.datum is {
        InlineDatum(data) -> {
          expect _: PoolDatum = data
          True
        }
        _ -> False
      }
    },
  )
}

/// Find a transaction output containing a StakingDatum.
/// Uses inline datum type checking to identify the staking output.
fn find_staking_output(tx: Transaction) -> Option<Output> {
  list.find(
    tx.outputs,
    fn(output) {
      when output.datum is {
        InlineDatum(data) -> {
          expect _: StakingDatum = data
          True
        }
        _ -> False
      }
    },
  )
}

/// Check if an asset class represents ADA (empty policy_id and asset_name).
fn is_ada(asset: AssetClass) -> Bool {
  asset.policy_id == "" && asset.asset_name == ""
}

// =============================================================================
// SECTION: Collect Fees Validation
// =============================================================================

/// Validate fee collection: verify source contract authorization, balance
/// updates, and datum integrity.
fn validate_collect_fees(
  old_datum: TreasuryDatum,
  fee_type: FeeType,
  amount: Int,
  asset: AssetClass,
  from_contract: ContractType,
  own_input: Input,
  tx: Transaction,
  registry: RegistryDatum,
) -> Void {
  // Verify fee originates from an authorized protocol contract
  let from_valid_contract =
    when from_contract is {
      Pool -> validate_from_pool(tx, registry)
      Staking -> validate_from_staking(tx, registry)
    }
  expect from_valid_contract

  // Find and validate treasury output datum
  expect Some(treasury_output) =
    find_output_at_address(tx.outputs, own_input.output.address)
  expect InlineDatum(new_datum_data) = treasury_output.datum
  expect new_datum: TreasuryDatum = new_datum_data

  // Verify balance updates based on asset type
  if is_ada(asset) {
    let old_ada =
      quantity_of(own_input.output.value, asset.policy_id, asset.asset_name)
    let new_ada =
      quantity_of(treasury_output.value, asset.policy_id, asset.asset_name)
    expect new_ada == old_ada + amount
    expect new_datum.ada_balance == old_datum.ada_balance + amount
  } else {
    let old_tokens =
      quantity_of(own_input.output.value, asset.policy_id, asset.asset_name)
    let new_tokens =
      quantity_of(treasury_output.value, asset.policy_id, asset.asset_name)
    expect new_tokens == old_tokens + amount
    expect new_datum.reward_token_balance == old_datum.reward_token_balance + amount
  }

  // Verify other datum fields are unchanged
  expect new_datum.total_ada_distributed == old_datum.total_ada_distributed
  expect new_datum.total_reward_tokens_distributed == old_datum.total_reward_tokens_distributed
  expect new_datum.fee_distribution == old_datum.fee_distribution
}

// =============================================================================
// SECTION: Distribute Fees Validation
// =============================================================================

/// Validate fee distribution: verify sufficient balance, calculate shares,
/// verify payments to pool and staking, and update treasury datum.
fn validate_distribute_fees(
  old_datum: TreasuryDatum,
  asset: AssetClass,
  amount_to_distribute: Int,
  own_input: Input,
  tx: Transaction,
  registry: RegistryDatum,
) -> Void {
  // Verify treasury has sufficient balance
  let has_balance =
    if is_ada(asset) {
      amount_to_distribute <= old_datum.ada_balance
    } else {
      amount_to_distribute <= old_datum.reward_token_balance
    }
  expect has_balance

  // Calculate distribution shares based on configured ratios
  let distribution = old_datum.fee_distribution
  let lp_share = amount_to_distribute * distribution.lp_ratio / 10000
  let staker_share = amount_to_distribute * distribution.staker_ratio / 10000
  // Note: protocol_share stays in treasury automatically (no transfer needed)

  // Verify LP share goes to the pool contract
  expect Some(pool_output) = find_pool_output(tx)
  expect
    quantity_of(pool_output.value, asset.policy_id, asset.asset_name) >= lp_share

  // Verify staker share goes to the staking contract
  expect Some(staking_output) = find_staking_output(tx)
  expect
    quantity_of(staking_output.value, asset.policy_id, asset.asset_name) >= staker_share

  // Validate treasury output datum
  expect Some(treasury_output) =
    find_output_at_address(tx.outputs, own_input.output.address)
  expect InlineDatum(new_datum_data) = treasury_output.datum
  expect new_datum: TreasuryDatum = new_datum_data
  let current_time = get_current_time(tx)

  // Verify balance and distribution tracking updates
  if is_ada(asset) {
    expect new_datum.ada_balance == old_datum.ada_balance - amount_to_distribute
    expect
      new_datum.total_ada_distributed == old_datum.total_ada_distributed + amount_to_distribute
  } else {
    expect
      new_datum.reward_token_balance == old_datum.reward_token_balance - amount_to_distribute
    expect
      new_datum.total_reward_tokens_distributed == old_datum.total_reward_tokens_distributed + amount_to_distribute
  }
  expect new_datum.last_distribution == current_time

  // Verify actual value transfer
  let old_value =
    quantity_of(own_input.output.value, asset.policy_id, asset.asset_name)
  let new_value =
    quantity_of(treasury_output.value, asset.policy_id, asset.asset_name)
  expect new_value == old_value - amount_to_distribute
}

// =============================================================================
// SECTION: Governance Validation
// =============================================================================

/// Validate a config update: verify multisig threshold, ratio integrity,
/// and that only the fee_distribution field changed.
fn validate_update_config(
  old_datum: TreasuryDatum,
  new_distribution: FeeDistribution,
  own_input: Input,
  tx: Transaction,
) -> Void {
  // Count governance signatures
  let governance_signatories = old_datum.governance_keys
  let signatures_count =
    list.foldl(
      governance_signatories,
      0,
      fn(pkh, count) {
        if is_signed_by(tx, pkh) {
          count + 1
        } else {
          count
        }
      },
    )
  expect signatures_count >= old_datum.min_signatures

  // Verify distribution ratios sum to 100%
  let ratios_sum =
    new_distribution.lp_ratio + new_distribution.staker_ratio + new_distribution.protocol_ratio
  expect ratios_sum == 10000

  // Validate treasury output datum
  expect Some(treasury_output) =
    find_output_at_address(tx.outputs, own_input.output.address)
  expect InlineDatum(new_datum_data) = treasury_output.datum
  expect new_datum: TreasuryDatum = new_datum_data

  // Verify only fee_distribution changed
  expect new_datum.fee_distribution == new_distribution
  expect new_datum.ada_balance == old_datum.ada_balance
  expect new_datum.reward_token_balance == old_datum.reward_token_balance
  expect new_datum.total_ada_distributed == old_datum.total_ada_distributed
  expect new_datum.total_reward_tokens_distributed == old_datum.total_reward_tokens_distributed
  expect new_datum.governance_keys == old_datum.governance_keys
  expect new_datum.min_signatures == old_datum.min_signatures
}

/// Validate a protocol withdrawal: verify multisig threshold, withdrawal
/// doesn't exceed protocol's share, and correct balance updates.
fn validate_withdraw_protocol(
  old_datum: TreasuryDatum,
  asset: AssetClass,
  amount: Int,
  own_input: Input,
  tx: Transaction,
) -> Void {
  // Count governance signatures
  let governance_signatories = old_datum.governance_keys
  let signatures_count =
    list.foldl(
      governance_signatories,
      0,
      fn(pkh, count) {
        if is_signed_by(tx, pkh) {
          count + 1
        } else {
          count
        }
      },
    )
  expect signatures_count >= old_datum.min_signatures

  // Calculate available protocol share
  let protocol_ratio = old_datum.fee_distribution.protocol_ratio
  let available_protocol_share =
    if is_ada(asset) {
      old_datum.ada_balance * protocol_ratio / 10000
    } else {
      old_datum.reward_token_balance * protocol_ratio / 10000
    }
  expect amount <= available_protocol_share

  // Validate treasury output datum
  expect Some(treasury_output) =
    find_output_at_address(tx.outputs, own_input.output.address)
  expect InlineDatum(new_datum_data) = treasury_output.datum
  expect new_datum: TreasuryDatum = new_datum_data

  // Verify balance update based on asset type
  if is_ada(asset) {
    expect new_datum.ada_balance == old_datum.ada_balance - amount
  } else {
    expect new_datum.reward_token_balance == old_datum.reward_token_balance - amount
  }

  // Verify actual value transfer
  let old_value =
    quantity_of(own_input.output.value, asset.policy_id, asset.asset_name)
  let new_value =
    quantity_of(treasury_output.value, asset.policy_id, asset.asset_name)
  expect new_value == old_value - amount
}

// =============================================================================
// SECTION: Placeholder Tests
// =============================================================================
// TODO: Implement comprehensive property-based tests using Aiken's test framework.

test collect_fees_datum_based() {
  True
}

test distribute_fees_datum_based() {
  True
}

test governance_multisig() {
  True
}

test datum_validation_pool() {
  True
}

test datum_validation_staking() {
  True
}
