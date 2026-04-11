// Cardano Lending Protocol - Lending Pool Validator
// Developed by grae.one (utxotools.io)
//
// Version: 8.0.0 - Registry Pattern Migration
// License: Apache-2.0
//
// The lending pool is the core contract of the Lending Protocol. It manages
// deposits, withdrawals, borrows, repayments, and liquidations. It supports
// both direct user operations and batched operations via the batcher system.
//
// All configuration is loaded from the centralized Registry via reference inputs,
// eliminating hardcoded contract addresses and enabling runtime parameter updates.

use aiken/collection/list
use lending/helpers.{
  count_orders, find_input_by_ref,
  find_output_at_address, find_own_input, find_position_by_ref, get_current_time,
  get_minting_policy_or_from_inputs, get_oracle_data,
  is_signed_by, parse_position_datum, script_address,
  time_elapsed_at_least, validate_batcher_license,
}
use lending/registry_helpers.{load_registry}
use lending/types.{
  AssetClass, BatchBorrow, BatchDeposit, BatchLiquidate, BatchRepay,
  BatchWithdraw, Borrow, Borrows, CancelConfigUpdate, Deposit, Deposits,
  ExecuteConfigUpdate, Liquidate, Liquidations, OBorrow, ODeposit, OLiquidate,
  ORepay, OWithdraw, Operation, OracleData, OrderDatum, PoolConfig, PoolDatum, PoolRedeemer,
  PositionDatum, ProposeConfigUpdate, RegistryDatum, Repay, Repayments, Withdraw,
  Withdrawals, calculate_dynamic_borrow_rate, calculate_interest,
  calculate_penalty_distribution, calculate_required_collateral,
  is_undercollateralized,
}
use cardano/address.{Script}
use cardano/assets.{PolicyId, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}

// =============================================================================
// SECTION: Validator Parameters
// =============================================================================

/// The lending pool only requires the registry script hash.
/// All other configuration (contract addresses, policies, limits) is
/// loaded dynamically from the Registry UTxO via reference inputs.
pub type LendingPoolParams {
  registry_script_hash: ByteArray,
}

// =============================================================================
// SECTION: Main Validator
// =============================================================================

validator lending_pool(params: LendingPoolParams) {
  spend(
    datum_opt: Option<PoolDatum>,
    redeemer: PoolRedeemer,
    own_ref: OutputReference,
    ctx: ScriptContext,
  ) {
    expect Some(datum) = datum_opt
    let tx = ctx.transaction
    let own_input = find_own_input(tx.inputs, own_ref)

    // Load protocol configuration from the Registry reference input
    let registry =
      load_registry(tx.reference_inputs, params.registry_script_hash)

    // Emergency shutdown check - all operations blocked when active
    expect !registry.emergency_shutdown

    // Verify the pool NFT is present (authenticates this pool UTxO)
    expect
      quantity_of(
        own_input.output.value,
        registry.pool_nft_policy,
        registry.pool_nft_name,
      ) == 1

    when redeemer is {

      // =========================================================================
      // DIRECT OPERATIONS
      // =========================================================================

      Deposit { amount } -> {
        expect !list.has(registry.paused_operations, Deposits)
        expect amount > 0
        expect amount >= registry.min_deposit_amount
        expect amount <= registry.max_single_deposit
        validate_deposit(datum, amount, own_input, tx, registry.position_hash)

        // Verify the pool received the deposited asset
        expect Some(pool_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        when datum.config.asset_lend.policy_id == "" is {
          True -> {
            // ADA deposit: verify lovelace increase
            let old_lovelace = quantity_of(own_input.output.value, "", "")
            let new_lovelace = quantity_of(pool_output.value, "", "")
            expect new_lovelace >= old_lovelace + amount
            True
          }
          False -> {
            // Native asset deposit: verify token quantity increase
            let old_qty =
              quantity_of(
                own_input.output.value,
                datum.config.asset_lend.policy_id,
                datum.config.asset_lend.asset_name,
              )
            let new_qty =
              quantity_of(
                pool_output.value,
                datum.config.asset_lend.policy_id,
                datum.config.asset_lend.asset_name,
              )
            expect new_qty >= old_qty + amount
            True
          }
        }
      }

      Withdraw { amount, position_ref } -> {
        expect !list.has(registry.paused_operations, Withdrawals)
        expect amount > 0
        expect amount >= registry.min_deposit_amount
        validate_withdraw(
          datum,
          amount,
          position_ref,
          own_input,
          tx,
          registry.position_hash,
        )

        // Verify the pool's balance decreased correctly
        expect Some(pool_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        when datum.config.asset_lend.policy_id == "" is {
          True -> {
            let old_lovelace = quantity_of(own_input.output.value, "", "")
            let new_lovelace = quantity_of(pool_output.value, "", "")
            new_lovelace >= old_lovelace - amount
          }
          False -> {
            let old_qty =
              quantity_of(
                own_input.output.value,
                datum.config.asset_lend.policy_id,
                datum.config.asset_lend.asset_name,
              )
            let new_qty =
              quantity_of(
                pool_output.value,
                datum.config.asset_lend.policy_id,
                datum.config.asset_lend.asset_name,
              )
            new_qty >= old_qty - amount
          }
        }
      }

      Borrow { amount, collateral_amount, position_ref } -> {
        expect !list.has(registry.paused_operations, Borrows)
        expect amount > 0
        expect amount >= registry.min_borrow_amount
        expect amount <= registry.max_single_borrow
        expect collateral_amount > 0

        // Check utilization doesn't exceed maximum after this borrow
        let new_borrowed = datum.total_borrowed + amount
        let utilization = new_borrowed * 10_000 / datum.total_deposited
        expect utilization <= registry.max_utilization_rate_bps

        validate_borrow(
          datum,
          amount,
          collateral_amount,
          position_ref,
          own_input,
          tx,
          registry.position_hash,
        )

        // Verify collateral was received by the pool
        expect Some(pool_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        when datum.config.asset_collateral.policy_id == "" is {
          True -> {
            let old_collateral = quantity_of(own_input.output.value, "", "")
            let new_collateral = quantity_of(pool_output.value, "", "")
            new_collateral >= old_collateral + collateral_amount
          }
          False -> {
            let old_collateral =
              quantity_of(
                own_input.output.value,
                datum.config.asset_collateral.policy_id,
                datum.config.asset_collateral.asset_name,
              )
            let new_collateral =
              quantity_of(
                pool_output.value,
                datum.config.asset_collateral.policy_id,
                datum.config.asset_collateral.asset_name,
              )
            new_collateral >= old_collateral + collateral_amount
          }
        }
      }

      Repay { amount, position_ref } -> {
        expect !list.has(registry.paused_operations, Repayments)
        expect amount > 0
        validate_repay(
          datum,
          amount,
          position_ref,
          own_input,
          tx,
          registry.position_hash,
        )

        // Verify the pool received the repaid asset
        expect Some(pool_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        when datum.config.asset_lend.policy_id == "" is {
          True -> {
            let old_lovelace = quantity_of(own_input.output.value, "", "")
            let new_lovelace = quantity_of(pool_output.value, "", "")
            expect new_lovelace >= old_lovelace + amount
            True
          }
          False -> {
            let old_qty =
              quantity_of(
                own_input.output.value,
                datum.config.asset_lend.policy_id,
                datum.config.asset_lend.asset_name,
              )
            let new_qty =
              quantity_of(
                pool_output.value,
                datum.config.asset_lend.policy_id,
                datum.config.asset_lend.asset_name,
              )
            expect new_qty >= old_qty + amount
            True
          }
        }
      }

      Liquidate { position_ref } -> {
        expect !list.has(registry.paused_operations, Liquidations)
        validate_liquidation(datum, position_ref, own_input, tx)
        expect Some(position_input) = find_input_by_ref(tx.inputs, position_ref)
        let position = parse_position_datum(position_input.output)
        let oracle_data = get_oracle_data(tx, datum.oracle_ref)
        is_undercollateralized(
          position.borrowed,
          position.collateral,
          oracle_data.price,
          datum.config.liquidation_threshold,
        )
      }

      // =========================================================================
      // BATCHED OPERATIONS (Batcher System)
      // =========================================================================

      BatchDeposit { license_idx, order_indices } -> {
        expect !list.has(registry.paused_operations, Deposits)
        let current_time = get_current_time(tx)

        // Validate the batcher license is active and not expired
        expect
          validate_batcher_license(
            tx,
            license_idx,
            registry.batcher_license_policy,
            current_time,
          )

        // Verify order count matches index list length
        let order_count = count_orders(tx.inputs, registry.orderbook_hash)
        expect order_count == list.length(order_indices)

        // Accumulate total deposited across all orders
        let (total_deposited, _prev_order_idx, _prev_pos_idx) =
          list.foldl(
            order_indices,
            (0, -1, -1),
            fn(indices, acc) {
              let (order_input_idx, position_output_idx) = indices
              let (sum, _prev_ord, _prev_pos) = acc
              expect Some(order_input) = list.at(tx.inputs, order_input_idx)

              // Verify input comes from the orderbook contract
              expect Script(order_hash) =
                order_input.output.address.payment_credential
              expect order_hash == registry.orderbook_hash

              // Parse and validate the order datum
              expect InlineDatum(order_datum_data) = order_input.output.datum
              expect order_datum: OrderDatum = order_datum_data
              when order_datum is {
                ODeposit { amount, deadline, .. } -> {
                  expect current_time <= deadline
                  expect amount >= registry.min_deposit_amount
                  expect amount <= registry.max_single_deposit
                  (sum + amount, order_input_idx, position_output_idx)
                }
                _ -> fail @"Invalid order type for BatchDeposit"
              }
            },
          )

        // Verify pool datum reflects the total deposit
        expect Some(pool_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        expect InlineDatum(new_datum_data) = pool_output.datum
        expect new_datum: PoolDatum = new_datum_data
        expect
          new_datum.total_deposited == datum.total_deposited + total_deposited
        True
      }

      BatchWithdraw { license_idx, order_indices } -> {
        expect !list.has(registry.paused_operations, Withdrawals)
        let current_time = get_current_time(tx)
        expect
          validate_batcher_license(
            tx,
            license_idx,
            registry.batcher_license_policy,
            current_time,
          )
        let order_count = count_orders(tx.inputs, registry.orderbook_hash)
        expect order_count == list.length(order_indices)

        let (total_withdrawn, _prev_order_idx, _prev_pos_idx) =
          list.foldl(
            order_indices,
            (0, -1, -1),
            fn(indices, acc) {
              let (order_input_idx, position_input_idx) = indices
              let (sum, _prev_ord, _prev_pos) = acc
              expect Some(order_input) = list.at(tx.inputs, order_input_idx)
              expect Script(order_hash) =
                order_input.output.address.payment_credential
              expect order_hash == registry.orderbook_hash
              expect InlineDatum(order_datum_data) = order_input.output.datum
              expect order_datum: OrderDatum = order_datum_data
              when order_datum is {
                OWithdraw { amount, deadline, .. } -> {
                  expect current_time <= deadline
                  expect amount >= registry.min_deposit_amount
                  (sum + amount, order_input_idx, position_input_idx)
                }
                _ -> fail @"Invalid order type for BatchWithdraw"
              }
            },
          )

        expect Some(pool_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        expect InlineDatum(new_datum_data) = pool_output.datum
        expect new_datum: PoolDatum = new_datum_data
        expect
          new_datum.total_deposited == datum.total_deposited - total_withdrawn
        True
      }

      BatchBorrow { license_idx, order_indices } -> {
        expect !list.has(registry.paused_operations, Borrows)
        let current_time = get_current_time(tx)
        expect
          validate_batcher_license(
            tx,
            license_idx,
            registry.batcher_license_policy,
            current_time,
          )
        let order_count = count_orders(tx.inputs, registry.orderbook_hash)
        expect order_count == list.length(order_indices)

        let (total_borrowed, total_collateral, _prev_order_idx, _prev_pos_idx, _prev_oracle_idx) =
          list.foldl(
            order_indices,
            (0, 0, -1, -1, -1),
            fn(indices, acc) {
              let (order_idx, position_idx, oracle_idx) = indices
              let (sum_borrow, sum_collateral, _prev_ord, _prev_pos, _prev_oracle) = acc
              expect Some(order_input) = list.at(tx.inputs, order_idx)
              expect Script(order_hash) =
                order_input.output.address.payment_credential
              expect order_hash == registry.orderbook_hash
              expect InlineDatum(order_datum_data) = order_input.output.datum
              expect order_datum: OrderDatum = order_datum_data
              when order_datum is {
                OBorrow { amount, collateral_amount, deadline, .. } -> {
                  expect current_time <= deadline
                  expect amount >= registry.min_borrow_amount
                  expect amount <= registry.max_single_borrow
                  // M2 fix: Validate collateral sufficiency against oracle price
                  expect Some(oracle_input) = list.at(tx.reference_inputs, oracle_idx)
                  expect InlineDatum(oracle_datum_data) = oracle_input.output.datum
                  expect oracle_data: OracleData = oracle_datum_data
                  let oracle_age = current_time - oracle_data.timestamp
                  expect oracle_age <= registry.max_oracle_age_borrow
                  let required_collateral =
                    calculate_required_collateral(
                      amount,
                      oracle_data.price,
                      datum.config.collateral_ratio,
                    )
                  expect collateral_amount >= required_collateral
                  (sum_borrow + amount, sum_collateral + collateral_amount, order_idx, position_idx, oracle_idx)
                }
                _ -> fail @"Invalid order type for BatchBorrow"
              }
            },
          )

        // Verify utilization stays within limits after all borrows
        let new_total_borrowed = datum.total_borrowed + total_borrowed
        let utilization = new_total_borrowed * 10_000 / datum.total_deposited
        expect utilization <= registry.max_utilization_rate_bps

        expect Some(pool_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        expect InlineDatum(new_datum_data) = pool_output.datum
        expect new_datum: PoolDatum = new_datum_data
        expect new_datum.total_borrowed == new_total_borrowed
        True
      }

      BatchRepay { license_idx, order_indices } -> {
        expect !list.has(registry.paused_operations, Repayments)
        let current_time = get_current_time(tx)
        expect
          validate_batcher_license(
            tx,
            license_idx,
            registry.batcher_license_policy,
            current_time,
          )
        let order_count = count_orders(tx.inputs, registry.orderbook_hash)
        expect order_count == list.length(order_indices)

        let (total_repaid, _prev_order_idx, _prev_pos_idx) =
          list.foldl(
            order_indices,
            (0, -1, -1),
            fn(indices, acc) {
              let (order_input_idx, position_input_idx) = indices
              let (sum, _prev_ord, _prev_pos) = acc
              expect Some(order_input) = list.at(tx.inputs, order_input_idx)
              expect Script(order_hash) =
                order_input.output.address.payment_credential
              expect order_hash == registry.orderbook_hash
              expect InlineDatum(order_datum_data) = order_input.output.datum
              expect order_datum: OrderDatum = order_datum_data
              when order_datum is {
                ORepay { amount, deadline, .. } -> {
                  expect current_time <= deadline
                  (sum + amount, order_input_idx, position_input_idx)
                }
                _ -> fail @"Invalid order type for BatchRepay"
              }
            },
          )

        expect Some(pool_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        expect InlineDatum(new_datum_data) = pool_output.datum
        expect new_datum: PoolDatum = new_datum_data
        expect new_datum.total_borrowed <= datum.total_borrowed - total_repaid
        True
      }

      BatchLiquidate { license_idx, order_indices } -> {
        expect !list.has(registry.paused_operations, Liquidations)
        let current_time = get_current_time(tx)
        expect
          validate_batcher_license(
            tx,
            license_idx,
            registry.batcher_license_policy,
            current_time,
          )
        let order_count = count_orders(tx.inputs, registry.orderbook_hash)
        expect order_count == list.length(order_indices)

        // M3 fix: Validate each liquidation order with undercollateralization check
        let (total_liquidated, _prev_order_idx, _prev_pos_idx) =
          list.foldl(
            order_indices,
            (0, -1, -1),
            fn(indices, acc) {
              let (order_input_idx, position_input_idx) = indices
              let (sum, _prev_ord, _prev_pos) = acc
              expect Some(order_input) = list.at(tx.inputs, order_input_idx)
              expect Script(order_hash) =
                order_input.output.address.payment_credential
              expect order_hash == registry.orderbook_hash
              expect InlineDatum(order_datum_data) = order_input.output.datum
              expect order_datum: OrderDatum = order_datum_data
              when order_datum is {
                OLiquidate { deadline, .. } -> {
                  expect current_time <= deadline
                  // Verify the position is actually undercollateralized
                  expect Some(position_input) = list.at(tx.inputs, position_input_idx)
                  let position = parse_position_datum(position_input.output)
                  expect position.borrowed > 0
                  let oracle_data = get_oracle_data(tx, datum.oracle_ref)
                  let oracle_age = current_time - oracle_data.timestamp
                  expect oracle_age <= registry.max_oracle_age_liquidate
                  expect
                    is_undercollateralized(
                      position.borrowed,
                      position.collateral,
                      oracle_data.price,
                      datum.config.liquidation_threshold,
                    )
                  (sum + 1, order_input_idx, position_input_idx)
                }
                _ -> fail @"Invalid order type for BatchLiquidate"
              }
            },
          )
        expect total_liquidated > 0
        True
      }

      // =========================================================================
      // GOVERNANCE OPERATIONS
      // =========================================================================

      ProposeConfigUpdate { new_config } -> {
        // Only the governance key can propose configuration changes
        expect
          list.has(tx.extra_signatories, datum.config.governance_script_hash)
        expect Some(pool_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        expect InlineDatum(new_datum_data) = pool_output.datum
        expect new_datum: PoolDatum = new_datum_data
        let current_time = get_current_time(tx)
        // Governance delay: 24 hours (86,400,000 ms)
        let activation_time = current_time + 86_400_000
        expect new_datum.config.pending_config == Some(new_config)
        expect new_datum.config.config_activation_time == Some(activation_time)
        True
      }

      ExecuteConfigUpdate -> {
        // Anyone can execute after the governance delay has passed
        expect Some(pending_config) = datum.config.pending_config
        expect Some(activation_time) = datum.config.config_activation_time
        let current_time = get_current_time(tx)
        expect current_time >= activation_time
        expect Some(pool_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        expect InlineDatum(new_datum_data) = pool_output.datum
        expect new_datum: PoolDatum = new_datum_data
        // Apply the pending config and clear the proposal
        expect new_datum.config == pending_config
        expect new_datum.config.pending_config == None
        expect new_datum.config.config_activation_time == None
        True
      }

      CancelConfigUpdate -> {
        // Only governance can cancel a pending proposal
        expect
          list.has(tx.extra_signatories, datum.config.governance_script_hash)
        expect Some(pool_output) =
          find_output_at_address(tx.outputs, own_input.output.address)
        expect InlineDatum(new_datum_data) = pool_output.datum
        expect new_datum: PoolDatum = new_datum_data
        expect new_datum.config.pending_config == None
        expect new_datum.config.config_activation_time == None
        True
      }
    }
  }

  else(_) {
    fail
  }
}

// =============================================================================
// SECTION: Deposit Validation Helpers
// =============================================================================

/// Validate a direct deposit operation.
/// Checks: pool datum integrity, user signature, position token handling,
/// and position output correctness.
fn validate_deposit(
  old_datum: PoolDatum,
  amount: Int,
  own_input: Input,
  tx: Transaction,
  position_script_hash: ByteArray,
) -> Void {
  expect Some(pool_output) =
    find_output_at_address(tx.outputs, own_input.output.address)
  expect InlineDatum(new_datum_data) = pool_output.datum
  expect new_datum: PoolDatum = new_datum_data
  expect new_datum.total_deposited == old_datum.total_deposited + amount
  expect new_datum.total_borrowed == old_datum.total_borrowed

  // Verify user signature (first signer is the depositor)
  expect Some(user_pkh) = list.head(tx.extra_signatories)
  expect is_signed_by(tx, user_pkh)

  let position_token_policy = get_minting_policy_or_from_inputs(tx)
  let has_existing_position =
    list.any(
      tx.inputs,
      fn(input) {
        quantity_of(input.output.value, position_token_policy, user_pkh) > 0
      },
    )
  let token_handled =
    has_existing_position || quantity_of(
      tx.mint,
      position_token_policy,
      user_pkh,
    ) == 1
  expect token_handled

  validate_position_for_deposit(
    tx,
    user_pkh,
    amount,
    position_script_hash,
    position_token_policy,
  )
}

/// Validate that a position output exists with correct deposit data.
fn validate_position_for_deposit(
  tx: Transaction,
  user_pkh: ByteArray,
  deposit_amount: Int,
  position_script_hash: ByteArray,
  policy_id: PolicyId,
) -> Void {
  let position_address = script_address(position_script_hash)
  expect Some(position_output) =
    find_output_at_address(tx.outputs, position_address)
  expect InlineDatum(position_data) = position_output.datum
  expect position: PositionDatum = position_data
  expect position.owner == user_pkh
  expect position.deposited >= deposit_amount

  // If no existing position, verify a new NFT was minted
  let has_existing_position =
    list.any(
      tx.inputs,
      fn(input) { quantity_of(input.output.value, policy_id, user_pkh) > 0 },
    )
  if has_existing_position {
    Void
  } else {
    let minted = quantity_of(tx.mint, policy_id, user_pkh) == 1
    expect minted
  }
}

// =============================================================================
// SECTION: Withdraw Validation Helpers
// =============================================================================

/// Validate a direct withdrawal operation.
/// Checks: pool datum integrity, user signature, position existence,
/// and correct balance adjustments.
fn validate_withdraw(
  old_datum: PoolDatum,
  withdraw_amount: Int,
  position_ref: OutputReference,
  own_input: Input,
  tx: Transaction,
  position_script_hash: ByteArray,
) -> Void {
  expect Some(pool_output) =
    find_output_at_address(tx.outputs, own_input.output.address)
  expect InlineDatum(new_datum_data) = pool_output.datum
  expect new_datum: PoolDatum = new_datum_data
  expect
    new_datum.total_deposited == old_datum.total_deposited - withdraw_amount
  expect new_datum.total_borrowed == old_datum.total_borrowed

  expect Some(user_pkh) = list.head(tx.extra_signatories)
  expect is_signed_by(tx, user_pkh)

  let position_token_policy = get_minting_policy_or_from_inputs(tx)
  let has_position =
    list.any(
      tx.inputs,
      fn(input) {
        quantity_of(input.output.value, position_token_policy, user_pkh) > 0
      },
    )
  expect has_position

  validate_position_for_withdraw(
    tx,
    position_ref,
    withdraw_amount,
    position_script_hash,
    position_token_policy,
  )
}

/// Validate position output after withdrawal.
/// If full withdrawal, the position NFT must be burned.
/// If partial, the position datum must reflect the decrease.
fn validate_position_for_withdraw(
  tx: Transaction,
  position_ref: OutputReference,
  withdraw_amount: Int,
  position_script_hash: ByteArray,
  policy_id: PolicyId,
) -> Void {
  expect Some(position_input) = find_position_by_ref(tx, position_ref)
  let old_position = parse_position_datum(position_input.output)
  if withdraw_amount >= old_position.deposited {
    // Full withdrawal: position NFT must be burned
    let burned = quantity_of(tx.mint, policy_id, old_position.owner) == -1
    expect burned
  } else {
    // Partial withdrawal: position datum must reflect the decrease
    let position_address = script_address(position_script_hash)
    expect Some(position_output) =
      find_output_at_address(tx.outputs, position_address)
    expect InlineDatum(new_position_data) = position_output.datum
    expect new_position: PositionDatum = new_position_data
    expect new_position.deposited == old_position.deposited - withdraw_amount
    expect new_position.owner == old_position.owner
  }
}

// =============================================================================
// SECTION: Borrow Validation Helpers
// =============================================================================

/// Validate a direct borrow operation.
/// Checks: oracle freshness, collateral sufficiency, available liquidity,
/// pool datum integrity, and position correctness.
fn validate_borrow(
  old_datum: PoolDatum,
  amount: Int,
  collateral_amount: Int,
  position_ref: OutputReference,
  own_input: Input,
  tx: Transaction,
  position_script_hash: ByteArray,
) -> Void {
  let current_time = get_current_time(tx)
  let oracle_data = get_oracle_data(tx, old_datum.oracle_ref)

  // Verify oracle data is fresh enough for borrowing (config-based, M1 fix)
  let oracle_age = current_time - oracle_data.timestamp
  expect oracle_age <= old_datum.config.max_oracle_age_borrow

  // Verify sufficient collateral based on oracle price
  let required_collateral =
    calculate_required_collateral(
      amount,
      oracle_data.price,
      old_datum.config.collateral_ratio,
    )
  expect collateral_amount >= required_collateral

  // Verify sufficient liquidity is available
  let available = old_datum.total_deposited - old_datum.total_borrowed
  expect amount <= available

  expect Some(pool_output) =
    find_output_at_address(tx.outputs, own_input.output.address)
  expect InlineDatum(new_datum_data) = pool_output.datum
  expect new_datum: PoolDatum = new_datum_data
  expect new_datum.total_borrowed == old_datum.total_borrowed + amount
  expect new_datum.total_deposited == old_datum.total_deposited

  // Verify collateral was transferred to the pool
  expect
    validate_collateral_transfer(
      own_input,
      pool_output,
      old_datum.config.asset_collateral,
      collateral_amount,
    )

  expect Some(user_pkh) = list.head(tx.extra_signatories)
  expect is_signed_by(tx, user_pkh)

  validate_position_for_borrow(
    tx,
    position_ref,
    user_pkh,
    amount,
    collateral_amount,
    current_time,
    position_script_hash,
  )
}

/// Verify that the expected collateral amount was transferred to the pool.
fn validate_collateral_transfer(
  pool_input: Input,
  pool_output: Output,
  collateral_asset: AssetClass,
  expected_amount: Int,
) -> Bool {
  let input_collateral =
    quantity_of(
      pool_input.output.value,
      collateral_asset.policy_id,
      collateral_asset.asset_name,
    )
  let output_collateral =
    quantity_of(
      pool_output.value,
      collateral_asset.policy_id,
      collateral_asset.asset_name,
    )
  output_collateral == input_collateral + expected_amount
}

/// Validate that a position output exists with correct borrow data.
fn validate_position_for_borrow(
  tx: Transaction,
  position_ref: OutputReference,
  user_pkh: ByteArray,
  borrow_amount: Int,
  collateral_amount: Int,
  current_time: Int,
  position_script_hash: ByteArray,
) -> Void {
  let position_address = script_address(position_script_hash)
  expect Some(position_output) =
    find_output_at_address(tx.outputs, position_address)
  expect InlineDatum(position_data) = position_output.datum
  expect position: PositionDatum = position_data
  expect position.owner == user_pkh
  expect position.borrowed >= borrow_amount
  expect position.collateral >= collateral_amount
  expect position.borrow_timestamp == current_time

  // Verify position NFT handling (existing or newly minted)
  let position_token_policy = get_minting_policy_or_from_inputs(tx)
  let has_existing_position =
    list.any(
      tx.inputs,
      fn(input) {
        quantity_of(input.output.value, position_token_policy, user_pkh) > 0
      },
    )
  let token_handled =
    has_existing_position || quantity_of(
      tx.mint,
      position_token_policy,
      user_pkh,
    ) == 1
  expect token_handled
}

// =============================================================================
// SECTION: Repay Validation Helpers
// =============================================================================

/// Validate a direct repay operation.
/// Calculates accrued interest, verifies repayment amount, distributes
/// interest shares, and handles collateral release.
fn validate_repay(
  old_datum: PoolDatum,
  repay_amount: Int,
  position_ref: OutputReference,
  own_input: Input,
  tx: Transaction,
  position_script_hash: ByteArray,
) -> Void {
  expect Some(user_pkh) = list.head(tx.extra_signatories)
  expect Some(position_input) = find_position_by_ref(tx, position_ref)
  let position = parse_position_datum(position_input.output)
  let current_time = get_current_time(tx)

  // Ensure at least 1 second has passed since last interest update
  expect time_elapsed_at_least(tx, position.last_interest_update, 1_000)

  let time_elapsed = current_time - position.last_interest_update
  let current_borrow_rate =
    calculate_dynamic_borrow_rate(
      old_datum.total_borrowed,
      old_datum.total_deposited,
      old_datum.config.base_rate,
      old_datum.config.slope1,
      old_datum.config.slope2,
      old_datum.config.optimal_utilization,
    )
  let interest =
    calculate_interest(position.borrowed, current_borrow_rate, time_elapsed)
  let total_due = position.borrowed + interest

  // Cannot repay more than total amount due
  expect repay_amount <= total_due

  expect Some(pool_output) =
    find_output_at_address(tx.outputs, own_input.output.address)
  expect InlineDatum(new_datum_data) = pool_output.datum
  expect new_datum: PoolDatum = new_datum_data

  // Calculate how much of the repayment goes to principal
  let principal_repaid =
    if repay_amount <= position.borrowed {
      repay_amount
    } else {
      position.borrowed
    }
  expect new_datum.total_borrowed == old_datum.total_borrowed - principal_repaid

  // Distribute interest to LPs, stakers, and treasury
  validate_interest_distribution(
    interest,
    tx,
    old_datum.config,
    old_datum.config.asset_lend,
    own_input,
    pool_output,
  )

  // Release collateral proportionally to the repayment
  validate_collateral_release_for_repay(
    position,
    pool_output,
    own_input,
    repay_amount,
    old_datum.config.asset_collateral,
  )

  let position_token_policy = get_minting_policy_or_from_inputs(tx)
  validate_position_after_repay(
    tx,
    position,
    repay_amount,
    user_pkh,
    position_script_hash,
    position_token_policy,
  )
  expect is_signed_by(tx, user_pkh)
}

/// Validate that interest is distributed correctly:
/// 75% to LPs (stays in pool), 20% to stakers, 5% to treasury.
fn validate_interest_distribution(
  interest: Int,
  tx: Transaction,
  pool_config: PoolConfig,
  asset: AssetClass,
  pool_input: Input,
  pool_output: Output,
) -> Void {
  let lp_share = interest * 75 / 100
  let staker_share = interest * 20 / 100
  let treasury_share = interest * 5 / 100
  let staking_address = script_address(pool_config.staking_script_hash)
  let treasury_address = script_address(pool_config.treasury_script_hash)
  let old_pool_value =
    quantity_of(pool_input.output.value, asset.policy_id, asset.asset_name)
  let new_pool_value =
    quantity_of(pool_output.value, asset.policy_id, asset.asset_name)

  // Pool must receive the LP share (75% of interest)
  expect new_pool_value >= old_pool_value + lp_share

  // Treasury must receive at least the treasury share
  let treasury_payment_valid =
    list.any(
      tx.outputs,
      fn(output) {
        output.address == treasury_address && quantity_of(
          output.value,
          asset.policy_id,
          asset.asset_name,
        ) >= treasury_share
      },
    )
  expect treasury_payment_valid

  // Staking contract must receive at least the staker share
  let staker_payment_valid =
    list.any(
      tx.outputs,
      fn(output) {
        output.address == staking_address && quantity_of(
          output.value,
          asset.policy_id,
          asset.asset_name,
        ) >= staker_share
      },
    )
  expect staker_payment_valid
}

/// Validate that collateral is released proportionally to the repayment.
/// The percentage of debt repaid determines the percentage of collateral released.
fn validate_collateral_release_for_repay(
  position: PositionDatum,
  pool_output: Output,
  pool_input: Input,
  repay_amount: Int,
  collateral_asset: AssetClass,
) -> Void {
  let repay_percentage =
    if position.borrowed == 0 {
      10000
    } else {
      repay_amount * 10000 / position.borrowed
    }
  let collateral_to_release = position.collateral * repay_percentage / 10000
  let pool_input_collateral =
    quantity_of(
      pool_input.output.value,
      collateral_asset.policy_id,
      collateral_asset.asset_name,
    )
  let pool_output_collateral =
    quantity_of(
      pool_output.value,
      collateral_asset.policy_id,
      collateral_asset.asset_name,
    )
  expect pool_output_collateral == pool_input_collateral - collateral_to_release
}

/// Validate position state after repayment.
/// If the full borrow is repaid, the position NFT must be burned.
fn validate_position_after_repay(
  tx: Transaction,
  old_position: PositionDatum,
  repay_amount: Int,
  user_pkh: ByteArray,
  position_script_hash: ByteArray,
  policy_id: PolicyId,
) -> Void {
  if repay_amount >= old_position.borrowed {
    // Full repayment: position NFT must be burned
    let burned = quantity_of(tx.mint, policy_id, user_pkh) == -1
    expect burned
  } else {
    // Partial repayment: position datum must reflect the decrease
    let position_address = script_address(position_script_hash)
    expect Some(position_output) =
      find_output_at_address(tx.outputs, position_address)
    expect InlineDatum(new_position_data) = position_output.datum
    expect new_position: PositionDatum = new_position_data
    let new_borrowed = old_position.borrowed - repay_amount
    expect new_position.borrowed == new_borrowed
    expect new_position.owner == old_position.owner
  }
}

// =============================================================================
// SECTION: Liquidation Validation Helpers
// =============================================================================

/// Validate a liquidation operation.
/// Checks: position has debt, oracle freshness, undercollateralization,
/// penalty calculation, penalty distribution, and position NFT burning.
fn validate_liquidation(
  old_datum: PoolDatum,
  position_ref: OutputReference,
  own_input: Input,
  tx: Transaction,
) -> Void {
  expect Some(position_input) = find_input_by_ref(tx.inputs, position_ref)
  let position = parse_position_datum(position_input.output)
  expect position.borrowed > 0
  expect position.collateral > 0

  let current_time = get_current_time(tx)
  let oracle_data = get_oracle_data(tx, old_datum.oracle_ref)

  // Verify oracle is fresh enough for liquidation (config-based, M1 fix)
  let oracle_age = current_time - oracle_data.timestamp
  expect oracle_age <= old_datum.config.max_oracle_age_liquidate

  // Verify the position is actually undercollateralized
  let undercollateralized =
    is_undercollateralized(
      position.borrowed,
      position.collateral,
      oracle_data.price,
      old_datum.config.liquidation_threshold,
    )
  expect undercollateralized

  // Calculate liquidation penalty and distribution
  let penalty_amount =
    position.collateral * old_datum.config.liquidation_penalty / 10000
  expect penalty_amount > 0
  expect penalty_amount <= position.collateral
  let liquidator_reward = position.collateral - penalty_amount
  let (lp_share, staker_share, treasury_share) =
    calculate_penalty_distribution(penalty_amount)

  // Verify pool datum updates
  expect Some(pool_output) =
    find_output_at_address(tx.outputs, own_input.output.address)
  expect InlineDatum(new_datum_data) = pool_output.datum
  expect new_datum: PoolDatum = new_datum_data
  expect
    new_datum.total_borrowed == old_datum.total_borrowed - position.borrowed
  // LP share is added to deposits as compensation for bad debt
  expect new_datum.total_deposited == old_datum.total_deposited + lp_share
  expect
    validate_penalty_payments(
      tx,
      staker_share,
      treasury_share,
      liquidator_reward,
      old_datum.config.asset_collateral,
      old_datum.config,
    )

  // Position must be closed and NFT burned
  let position_token_policy = get_minting_policy_or_from_inputs(tx)
  let position_closed =
    quantity_of(tx.mint, position_token_policy, position.owner) == -1
  expect position_closed
}

/// Validate that liquidation penalty payments are correctly distributed
/// to the staking contract, treasury, and liquidator.
fn validate_penalty_payments(
  tx: Transaction,
  staker_share: Int,
  treasury_share: Int,
  liquidator_reward: Int,
  collateral_asset: AssetClass,
  pool_config: PoolConfig,
) -> Bool {
  let staking_address = script_address(pool_config.staking_script_hash)
  let treasury_address = script_address(pool_config.treasury_script_hash)

  let treasury_payment_valid =
    list.any(
      tx.outputs,
      fn(output) {
        output.address == treasury_address && quantity_of(
          output.value,
          collateral_asset.policy_id,
          collateral_asset.asset_name,
        ) >= treasury_share
      },
    )
  let staker_payment_valid =
    list.any(
      tx.outputs,
      fn(output) {
        output.address == staking_address && quantity_of(
          output.value,
          collateral_asset.policy_id,
          collateral_asset.asset_name,
        ) >= staker_share
      },
    )
  let liquidator_payment_valid =
    list.any(
      tx.outputs,
      fn(output) {
        quantity_of(
          output.value,
          collateral_asset.policy_id,
          collateral_asset.asset_name,
        ) >= liquidator_reward
      },
    )
  staker_payment_valid && treasury_payment_valid && liquidator_payment_valid
}
