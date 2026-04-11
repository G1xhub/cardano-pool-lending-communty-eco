// Cardano Lending Protocol - Staker NFT Minting Policy
// Developed by grae.one (utxotools.io)
//
// Version: 8.0.0 - Parameterized (C1 Fix)
// License: Apache-2.0
//
// Minting policy for staker position NFTs. Each staker is identified
// by a unique NFT whose token name is the owner's public key hash.
//
// SECURITY:
// - Only the staking contract can mint staker NFTs (staking input required)
// - The owner must sign the transaction (token name = owner PKH)
// - Minted NFTs must be sent to the staker position script address
// - Burns are allowed without additional checks (handled by staker_position validator)
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

pub type StakerNftParams {
  /// Script hash of the staking validator (only staking can trigger minting)
  staking_script_hash: ByteArray,
  /// Script hash of the staker position validator (where staker NFTs must be sent)
  staker_position_script_hash: ByteArray,
}

// =============================================================================
// SECTION: Minting Policy
// =============================================================================

validator staker_nft(params: StakerNftParams) {
  mint(redeemer: Data, own_policy_id: ByteArray, ctx: ScriptContext) {
    let tx = ctx.transaction

    // CHECK 1: Staking contract input must be present
    let has_staking_input = list.any(
      tx.inputs,
      fn(input) {
        when input.output.address.payment_credential is {
          Script(hash) -> hash == params.staking_script_hash
          _ -> False
        }
      }
    )
    expect has_staking_input

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
            // MINT: Owner must sign and NFT must go to staker position contract
            let owner_pkh = token_name // Token name = owner PKH
            let owner_signed = list.has(tx.extra_signatories, owner_pkh)

            let staker_position_address = from_script(params.staker_position_script_hash)
            let goes_to_staker_position = list.any(
              tx.outputs,
              fn(output) {
                output.address == staker_position_address &&
                quantity_of(output.value, own_policy_id, token_name) == 1
              }
            )

            valid_quantity && owner_signed && goes_to_staker_position
          } else {
            // BURN: Only quantity validation needed
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
