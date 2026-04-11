// Cardano Lending Protocol - Position NFT Minting Policy
// Developed by grae.one (utxotools.io)
//
// Version: 8.0.0 - Parameterized (C1 Fix)
// License: Apache-2.0
//
// Minting policy for borrower position NFTs. Each position is identified
// by a unique NFT whose token name is the owner's public key hash.
//
// SECURITY:
// - Only the lending pool contract can mint position NFTs (pool input required)
// - The owner must sign the transaction (token name = owner PKH)
// - Minted NFTs must be sent to the position script address
// - Burns are allowed without additional checks (handled by position validator)
//
// Parameterized to accept script hashes, making it compatible with
// contract upgrades without redeploying the policy.

use aiken/collection/list
use cardano/address.{Script, from_script}
use cardano/assets.{flatten, quantity_of}
use cardano/script_context.{ScriptContext}

// =============================================================================
// SECTION: Parameters
// =============================================================================

pub type PositionNftParams {
  /// Script hash of the lending pool validator (only pool can mint position NFTs)
  pool_script_hash: ByteArray,
  /// Script hash of the position validator (where position NFTs must be sent)
  position_script_hash: ByteArray,
}

// =============================================================================
// SECTION: Minting Policy
// =============================================================================

validator position_nft(params: PositionNftParams) {
  mint(redeemer: Data, own_policy_id: ByteArray, ctx: ScriptContext) {
    let tx = ctx.transaction

    // CHECK 1: Pool input must be present (only pool can trigger minting)
    let has_pool_input = list.any(
      tx.inputs,
      fn(input) {
        when input.output.address.payment_credential is {
          Script(hash) -> hash == params.pool_script_hash
          _ -> False
        }
      }
    )
    expect has_pool_input

    // CHECK 2: Validate each minted token under this policy
    let minted_tokens = flatten(tx.mint)
    expect list.all(
      minted_tokens,
      fn(token) {
        let (policy, token_name, quantity) = token

        if policy == own_policy_id {
          // Must be exactly +1 (mint) or -1 (burn)
          let valid_quantity = quantity == 1 || quantity == -1

          if quantity == 1 {
            // MINT: Owner must sign and NFT must go to position contract
            let owner_pkh = token_name // Token name = owner PKH
            let owner_signed = list.has(tx.extra_signatories, owner_pkh)

            let position_address = from_script(params.position_script_hash)
            let goes_to_position = list.any(
              tx.outputs,
              fn(output) {
                output.address == position_address &&
                quantity_of(output.value, own_policy_id, token_name) == 1
              }
            )

            valid_quantity && owner_signed && goes_to_position
          } else {
            // BURN: Only quantity validation needed
            // (position validator handles burn authorization logic)
            valid_quantity
          }
        } else {
          // Ignore tokens from other policies
          True
        }
      }
    )

    True
  }

  else(_) { fail }
}
