// Cardano Lending Protocol - Orderbook Validator
// Developed by grae.one (utxotools.io)
//
// Version: 8.0.0 - Registry Pattern Migration
// License: Apache-2.0
//
// Manages order UTxOs for the batcher system. Users submit orders by creating
// UTxOs at the orderbook script address. Authorized batchers can then apply
// (execute) orders in batches, or users can cancel their own orders.
//
// Orders can be: Deposit, Withdraw, Borrow, Repay, or Liquidation.
// Each order has an owner, amount, optional position reference, batcher fee,
// and a deadline after which the order can be cancelled by anyone.

use aiken/collection/list
use lending/helpers.{find_own_input, get_current_time, is_signed_by}
use lending/registry_helpers.{load_registry}
use lending/types.{
  Borrows, ClaimRewardsOp, Deposits, Liquidations, OBorrow, ODeposit, OLiquidate,
  ORepay, OWithdraw, Operation, OrderDatum, PoolDatum, RegistryDatum, Repayments,
  StakingOp, Unstaking, Withdrawals,
}
use cardano/address.{Script}
use cardano/assets.{quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{InlineDatum, OutputReference}

// =============================================================================
// SECTION: Validator Parameters
// =============================================================================

/// The orderbook only requires the registry script hash.
/// Pool address and other configuration comes from the Registry.
pub type OrderbookParams {
  registry_script_hash: ByteArray,
}

// =============================================================================
// SECTION: Redeemers
// =============================================================================

/// Order actions: apply (execute by batcher) or cancel (by owner or after deadline).
pub type OrderRedeemer {
  /// Apply the order against a specific pool input (by an authorized batcher)
  ApplyOrder { pool_input_idx: Int }
  /// Cancel the order (by owner anytime, or by anyone after deadline)
  CancelOrder
}

// =============================================================================
// SECTION: Main Validator
// =============================================================================

validator orderbook(params: OrderbookParams) {
  spend(
    datum_opt: Option<OrderDatum>,
    redeemer: OrderRedeemer,
    own_ref: OutputReference,
    ctx: ScriptContext,
  ) {
    expect Some(order_datum) = datum_opt
    let tx = ctx.transaction
    let own_input = find_own_input(tx.inputs, own_ref)

    // Load protocol configuration from Registry
    let registry =
      load_registry(tx.reference_inputs, params.registry_script_hash)

    // Emergency shutdown check
    expect !registry.emergency_shutdown

    when redeemer is {

      // =========================================================================
      // APPLY ORDER: Execute an order against the lending pool
      // =========================================================================
      ApplyOrder { pool_input_idx } -> {
        // Verify the specific operation is not paused
        let operation = get_operation_type(order_datum)
        expect !list.has(registry.paused_operations, operation)

        // Verify the pool input exists at the specified index
        expect Some(pool_input) = list.at(tx.inputs, pool_input_idx)

        // Verify it's the correct lending pool (from registry)
        expect Script(pool_hash) = pool_input.output.address.payment_credential
        expect pool_hash == registry.lending_pool_hash

        // Verify pool datum is valid
        expect InlineDatum(pool_datum_data) = pool_input.output.datum
        expect _pool_datum: PoolDatum = pool_datum_data

        // Verify pool NFT is present (using registry policy)
        expect
          quantity_of(
            pool_input.output.value,
            registry.pool_nft_policy,
            registry.pool_nft_name,
          ) == 1

        // Verify order deadline has not expired
        let current_time = get_current_time(tx)
        let deadline = get_order_deadline(order_datum)
        expect current_time <= deadline

        True
      }

      // =========================================================================
      // CANCEL ORDER: Cancel an order by owner or after deadline
      // =========================================================================
      CancelOrder -> {
        let owner = get_order_owner(order_datum)
        let deadline = get_order_deadline(order_datum)
        let current_time = get_current_time(tx)

        // Allow cancellation if: deadline expired OR owner signed
        let deadline_expired = current_time > deadline
        let owner_signed = is_signed_by(tx, owner)
        expect deadline_expired || owner_signed
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

/// Extract the owner (public key hash) from any order variant.
fn get_order_owner(order: OrderDatum) -> ByteArray {
  when order is {
    ODeposit { owner, .. } -> owner
    OWithdraw { owner, .. } -> owner
    OBorrow { owner, .. } -> owner
    ORepay { owner, .. } -> owner
    OLiquidate { owner, .. } -> owner
  }
}

/// Extract the deadline from any order variant.
fn get_order_deadline(order: OrderDatum) -> Int {
  when order is {
    ODeposit { deadline, .. } -> deadline
    OWithdraw { deadline, .. } -> deadline
    OBorrow { deadline, .. } -> deadline
    ORepay { deadline, .. } -> deadline
    OLiquidate { deadline, .. } -> deadline
  }
}

/// Map an order variant to its corresponding operation type.
/// Used for pause/resume checks against the registry.
fn get_operation_type(order: OrderDatum) -> Operation {
  when order is {
    ODeposit { .. } -> Deposits
    OWithdraw { .. } -> Withdrawals
    OBorrow { .. } -> Borrows
    ORepay { .. } -> Repayments
    OLiquidate { .. } -> Liquidations
  }
}
