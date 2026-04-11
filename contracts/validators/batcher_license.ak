// Cardano Lending Protocol - Batcher License Minting Policy
// Developed by grae.one (utxotools.io)
//
// Version: 8.0.0 - Deduplicated (H1 Fix)
// License: Apache-2.0
//
// Time-gated access control for the batcher system. Authorized batchers
// must hold a valid license token to submit batch transactions.
//
// License tokens encode their expiration deadline as the token name
// (ByteArray representation of a Unix timestamp in milliseconds).
// When the deadline passes, the license is no longer valid for new batches
// but can be burned by the admin.

use aiken/collection/list
use lending/helpers.{int_to_bytearray}
use cardano/assets.{PolicyId, flatten, quantity_of}
use cardano/script_context.{ScriptContext}
use cardano/transaction.{OutputReference, Transaction}

// =============================================================================
// SECTION: Types
// =============================================================================

pub type BatcherLicenseRedeemer {
  /// Mint a new batcher license with the specified deadline
  MintLicense { deadline: Int }
  /// Burn an existing batcher license
  BurnLicense
}

pub type BatcherLicenseParams {
  /// Admin public key hash authorized to mint/burn licenses
  admin_pkh: ByteArray,
  /// Output reference of the pool this license is tied to
  pool_id: OutputReference,
}

// =============================================================================
// SECTION: Minting Policy
// =============================================================================

validator batcher_license(params: BatcherLicenseParams) {
  mint(
    redeemer: BatcherLicenseRedeemer,
    policy_id: PolicyId,
    ctx: ScriptContext,
  ) {
    let tx = ctx.transaction
    when redeemer is {
      MintLicense { deadline } -> {
        // Only admin can mint new licenses
        expect list.has(tx.extra_signatories, params.admin_pkh)

        // Encode deadline as token name for on-chain verification
        let deadline_bytes = int_to_bytearray(deadline)

        // Verify exactly 1 token is minted with the deadline as name
        let minted_quantity = quantity_of(tx.mint, policy_id, deadline_bytes)
        expect minted_quantity == 1

        // Verify the pool UTxO is referenced (license is pool-specific)
        let pool_referenced =
          list.any(
            tx.inputs,
            fn(input) { input.output_reference == params.pool_id },
          ) || list.any(
            tx.reference_inputs,
            fn(input) { input.output_reference == params.pool_id },
          )

        // Final validation: pool referenced, admin signed, valid deadline
        expect pool_referenced && list.has(tx.extra_signatories, params.admin_pkh) && deadline > 0
        True
      }
      BurnLicense -> {
        // Only admin can burn licenses
        expect list.has(tx.extra_signatories, params.admin_pkh)

        // Verify all minted amounts are negative (burning only)
        let all_burned =
          list.foldl(
            flatten(tx.mint),
            True,
            fn(asset, acc) {
              let (_policy, _name, quantity) = asset
              acc && quantity < 0
            },
          )
        expect all_burned

        expect list.has(tx.extra_signatories, params.admin_pkh)
        True
      }
    }
  }

  else(_) {
    fail
  }
}
