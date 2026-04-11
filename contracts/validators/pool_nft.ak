// Cardano Lending Protocol - Pool NFT Minting Policy
// Developed by grae.one (utxotools.io)
//
// Version: 8.0.0 - Parameterized (C1/C2 Fix)
// License: Apache-2.0
//
// One-Time-Mint (OTM) policy for pool identity NFTs.
// Exactly one pool NFT is minted per lending pool and must be sent
// directly to the pool's script address. The NFT serves as a unique
// identifier to authenticate pool UTxOs.
//
// SECURITY:
// - Admin signature is required for minting (prevents unauthorized pool creation)
// - Exactly one token is minted per transaction (one-time-mint)
// - The NFT must be sent directly to the lending pool script address
// - Token name is fixed to "LendingPool" for canonical identification

use aiken/collection/list
use cardano/address.{from_script}
use cardano/assets.{quantity_of}
use cardano/script_context.{ScriptContext}

// =============================================================================
// SECTION: Parameters
// =============================================================================

pub type PoolNftParams {
  /// Admin public key hash authorized to mint pool NFTs
  admin_pkh: ByteArray,
  /// Script hash of the lending pool validator (NFT destination)
  pool_script_hash: ByteArray,
}

/// Token name for the pool identity NFT ("LendingPool")
const nft_token_name: ByteArray = #"4c656e64696e67506f6f6c"

// =============================================================================
// SECTION: Minting Policy
// =============================================================================

validator pool_nft(params: PoolNftParams) {
  mint(_r: Data, own_policy_id: ByteArray, ctx: ScriptContext) {
    let tx = ctx.transaction

    // SECURITY: Admin must authorize pool NFT minting (C2 fix)
    expect list.has(tx.extra_signatories, params.admin_pkh)

    // Exactly 1 token must be minted with the canonical token name
    expect quantity_of(tx.mint, own_policy_id, nft_token_name) == 1

    // The minted NFT must be sent to the pool script address
    expect list.any(
      tx.outputs,
      fn(output) {
        output.address == from_script(params.pool_script_hash) &&
        quantity_of(output.value, own_policy_id, nft_token_name) == 1
      }
    )
    True
  }
}
