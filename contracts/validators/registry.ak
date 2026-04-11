// Cardano Lending Protocol - Registry Validator
// Developed by grae.one (utxotools.io)
//
// Version: 8.0.0 - Registry Pattern Migration
// License: Apache-2.0
//
// Central configuration management for the entire Lending Protocol.
// The Registry UTxO serves as the single source of truth for all contract
// addresses, minting policies, protocol parameters, risk limits, and
// governance settings.
//
// Other validators load the Registry via reference inputs to obtain their
// configuration at runtime, enabling parameter updates without contract upgrades.

use aiken/collection/list
use aiken/interval.{Finite}
use lending/types.{
  Borrows, CancelUpdate, CancelUpgrade, ClaimRewardsOp, Deposits,
  EmergencyShutdown, ExecuteUpdate, ExecuteUpgrade, Liquidations, Operation,
  PauseOperation, PendingUpdate, ProposeUpdate, ProposeUpgrade, ReadRegistry,
  RegistryDatum, RegistryRedeemer, Repayments, ResumeOperation, ResumeOperations,
  StakingOp, Unstaking, UpdateRegistry, UpgradeProposal, Withdrawals,
}
use cardano/address.{Script}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}

// =============================================================================
// SECTION: Main Validator
// =============================================================================

validator registry {
  spend(
    datum_opt: Option<RegistryDatum>,
    redeemer: RegistryRedeemer,
    own_ref: OutputReference,
    ctx: ScriptContext,
  ) {
    expect Some(current_datum) = datum_opt
    let tx = ctx.transaction

    when redeemer is {

      // =========================================================================
      // ADMIN UPDATES
      // =========================================================================

      /// Direct update by admin (for minor changes like parameter tuning).
      /// Version must be incremented and timestamp must advance.
      UpdateRegistry { new_datum } -> {
        expect list.has(tx.extra_signatories, current_datum.admin_pkh)

        expect Some(own_output) =
          find_own_output(tx.outputs, own_ref, tx.inputs)
        expect InlineDatum(output_datum_data) = own_output.datum
        expect output_datum: RegistryDatum = output_datum_data

        // Verify datum was applied correctly
        expect output_datum == new_datum

        // Version must always increment
        expect new_datum.version == current_datum.version + 1

        // Timestamp must advance (prevents replay)
        expect new_datum.last_updated > current_datum.last_updated
        True
      }

      /// Propose a time-locked update (for major changes requiring governance delay).
      ProposeUpdate { new_datum } -> {
        expect list.has(tx.extra_signatories, current_datum.admin_pkh)

        expect Some(own_output) =
          find_own_output(tx.outputs, own_ref, tx.inputs)
        expect InlineDatum(output_datum_data) = own_output.datum
        expect output_datum: RegistryDatum = output_datum_data

        let current_time = get_current_time(tx)
        let activation_time = current_time + current_datum.governance_delay

        let pending_update =
          PendingUpdate {
            new_datum,
            proposed_at: current_time,
            activation_time,
          }

        // Verify pending update was stored correctly
        expect output_datum.pending_update == Some(pending_update)

        // Critical contract hashes must not change during proposal
        expect output_datum.lending_pool_hash == current_datum.lending_pool_hash
        expect output_datum.orderbook_hash == current_datum.orderbook_hash
        True
      }

      /// Execute a previously proposed update after the governance delay.
      /// Anyone can trigger execution (decentralized enforcement).
      ExecuteUpdate -> {
        expect Some(pending) = current_datum.pending_update
        let current_time = get_current_time(tx)
        expect current_time >= pending.activation_time

        expect Some(own_output) =
          find_own_output(tx.outputs, own_ref, tx.inputs)
        expect InlineDatum(output_datum_data) = own_output.datum
        expect output_datum: RegistryDatum = output_datum_data

        // Apply the pending update
        expect output_datum == pending.new_datum

        // Clear the pending update
        expect output_datum.pending_update == None
        True
      }

      /// Cancel a pending update proposal (admin only).
      CancelUpdate -> {
        expect list.has(tx.extra_signatories, current_datum.admin_pkh)

        expect Some(own_output) =
          find_own_output(tx.outputs, own_ref, tx.inputs)
        expect InlineDatum(output_datum_data) = own_output.datum
        expect output_datum: RegistryDatum = output_datum_data

        // Clear pending update
        expect output_datum.pending_update == None

        // Contract hashes must remain unchanged
        expect output_datum.lending_pool_hash == current_datum.lending_pool_hash
        True
      }

      // =========================================================================
      // EMERGENCY CONTROLS
      // =========================================================================

      /// Trigger emergency shutdown: pauses ALL protocol operations.
      /// Only the admin can activate emergency shutdown.
      EmergencyShutdown -> {
        expect list.has(tx.extra_signatories, current_datum.admin_pkh)

        expect Some(own_output) =
          find_own_output(tx.outputs, own_ref, tx.inputs)
        expect InlineDatum(output_datum_data) = own_output.datum
        expect output_datum: RegistryDatum = output_datum_data

        // Verify shutdown activated
        expect output_datum.emergency_shutdown == True

        // All operations must be paused during emergency shutdown
        let all_operations =
          [
            Deposits, Withdrawals, Borrows, Repayments, Liquidations, StakingOp,
            Unstaking, ClaimRewardsOp,
          ]
        expect output_datum.paused_operations == all_operations
        True
      }

      /// Resume all operations after an emergency shutdown (admin only).
      ResumeOperations -> {
        expect list.has(tx.extra_signatories, current_datum.admin_pkh)

        expect Some(own_output) =
          find_own_output(tx.outputs, own_ref, tx.inputs)
        expect InlineDatum(output_datum_data) = own_output.datum
        expect output_datum: RegistryDatum = output_datum_data

        // Verify shutdown deactivated
        expect output_datum.emergency_shutdown == False

        // All operations resumed
        expect output_datum.paused_operations == []
        True
      }

      /// Pause a specific operation type (admin only).
      PauseOperation { operation } -> {
        expect list.has(tx.extra_signatories, current_datum.admin_pkh)

        expect Some(own_output) =
          find_own_output(tx.outputs, own_ref, tx.inputs)
        expect InlineDatum(output_datum_data) = own_output.datum
        expect output_datum: RegistryDatum = output_datum_data

        // Verify operation was added to paused list
        expect list.has(output_datum.paused_operations, operation)
        True
      }

      /// Resume a specific paused operation type (admin only).
      ResumeOperation { operation } -> {
        expect list.has(tx.extra_signatories, current_datum.admin_pkh)

        expect Some(own_output) =
          find_own_output(tx.outputs, own_ref, tx.inputs)
        expect InlineDatum(output_datum_data) = own_output.datum
        expect output_datum: RegistryDatum = output_datum_data

        // Verify operation was removed from paused list
        expect !list.has(output_datum.paused_operations, operation)
        True
      }

      // =========================================================================
      // UPGRADE MANAGEMENT
      // =========================================================================

      /// Propose a contract upgrade with new script hashes (time-locked).
      ProposeUpgrade { new_hashes } -> {
        expect list.has(tx.extra_signatories, current_datum.admin_pkh)

        expect Some(own_output) =
          find_own_output(tx.outputs, own_ref, tx.inputs)
        expect InlineDatum(output_datum_data) = own_output.datum
        expect output_datum: RegistryDatum = output_datum_data

        let current_time = get_current_time(tx)
        let execution_time = current_time + current_datum.governance_delay

        let proposal =
          UpgradeProposal {
            new_contract_hashes: new_hashes,
            proposed_at: current_time,
            execution_time,
            proposer: current_datum.admin_pkh,
          }

        expect output_datum.upgrade_proposal == Some(proposal)
        True
      }

      /// Execute a proposed contract upgrade after governance delay.
      /// Anyone can trigger execution after the delay passes.
      ExecuteUpgrade -> {
        expect Some(proposal) = current_datum.upgrade_proposal
        let current_time = get_current_time(tx)
        expect current_time >= proposal.execution_time

        expect Some(own_output) =
          find_own_output(tx.outputs, own_ref, tx.inputs)
        expect InlineDatum(output_datum_data) = own_output.datum
        expect output_datum: RegistryDatum = output_datum_data

        // Clear the upgrade proposal
        expect output_datum.upgrade_proposal == None
        True
      }

      /// Cancel a proposed contract upgrade (admin only).
      CancelUpgrade -> {
        expect list.has(tx.extra_signatories, current_datum.admin_pkh)

        expect Some(own_output) =
          find_own_output(tx.outputs, own_ref, tx.inputs)
        expect InlineDatum(output_datum_data) = own_output.datum
        expect output_datum: RegistryDatum = output_datum_data

        expect output_datum.upgrade_proposal == None
        True
      }

      // =========================================================================
      // READ-ONLY
      // =========================================================================

      /// Read the registry data (always succeeds).
      /// Used when the registry is included as a reference input by other validators.
      ReadRegistry ->
        True
    }
  }

  else(_) {
    fail
  }
}

// =============================================================================
// SECTION: Helper Functions
// =============================================================================

/// Find the registry's own output by matching the spent input's address.
fn find_own_output(
  outputs: List<Output>,
  own_ref: OutputReference,
  inputs: List<Input>,
) -> Option<Output> {
  expect Some(own_input) =
    list.find(inputs, fn(input) { input.output_reference == own_ref })
  list.find(outputs, fn(output) { output.address == own_input.output.address })
}

/// Get current time from the transaction validity range lower bound.
fn get_current_time(tx: Transaction) -> Int {
  when tx.validity_range.lower_bound.bound_type is {
    Finite(time) -> time
    _ -> fail @"Invalid time range"
  }
}
