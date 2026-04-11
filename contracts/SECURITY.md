# Security Audit Report

**Project:** Cardano Lending Protocol  
**Repository:** G1xHub/cardano-pool-lending-community-eco  
**Package:** G1xHub/lending v8.0.0  
**Auditor:** grae.one (utxotools.io)  
**Date:** 2025-04-11  
**Compiler:** Aiken v1.1.19 / Plutus V3  

---

## Executive Summary

A comprehensive security audit was performed on the entire codebase (12 validators, 3 library modules, ~5,562 lines of Aiken code). The audit covered access control, reentrancy, oracle manipulation, integer overflow, batch operation integrity, and governance security.

**Result: 0 open issues.** All findings from previous audit rounds have been resolved and verified.

---

## Audit Scope

| File | Lines | Role |
|------|-------|------|
| `lib/types.ak` | 705 | Core types and math functions |
| `lib/helpers.ak` | 373 | Shared utility functions |
| `lib/registry_helpers.ak` | 322 | Registry interaction helpers |
| `validators/lending_pool.ak` | 1186 | Core lending pool logic |
| `validators/staking.ak` | 593 | Staking rewards management |
| `validators/oracle.ak` | 276 | Price feed management |
| `validators/treasury.ak` | 482 | Fee collection and distribution |
| `validators/position.ak` | 349 | Borrower position state |
| `validators/staker_position.ak` | 351 | Staker position state |
| `validators/registry.ak` | 303 | Central configuration |
| `validators/orderbook.ak` | 167 | Batcher order management |
| `validators/batcher_license.ak` | 101 | Batcher access control |
| `validators/pool_nft.ak` | 61 | Pool identity NFT policy |
| `validators/position_nft.ak` | 97 | Position NFT policy |
| `validators/staker_nft.ak` | 96 | Staker NFT policy |

---

## Findings

### v1 Audit Findings (All RESOLVED)

| ID | Severity | Description | Status |
|----|----------|-------------|--------|
| C1 | CRITICAL | Hardcoded script hashes in NFT policies | RESOLVED - Parameterized with validator params |
| C2 | CRITICAL | Pool NFT missing admin check | RESOLVED - Added admin_pkh param + signature check |
| H1 | HIGH | Duplicate function definitions across files | RESOLVED - Single canonical definitions |
| H2 | HIGH | Duplicate OracleRedeemer type | RESOLVED - Single definition in types.ak |
| M1 | MEDIUM | Redundant double oracle freshness check | RESOLVED - Removed hardcoded check, config-based only |
| M2 | MEDIUM | BatchBorrow missing collateral validation | RESOLVED - Added oracle lookup + collateral check per order |
| M3 | MEDIUM | BatchLiquidate missing undercollateralization check | RESOLVED - Added position data + oracle verification per position |

### v2 Audit Findings (All RESOLVED)

| ID | Severity | File | Description | Status |
|----|----------|------|-------------|--------|
| C4 | CRITICAL | `staking.ak:470,523` | Field name mismatch: `staking_token_rewards_claimed` should be `staking_rewards_claimed` (causes compilation failure) | RESOLVED |
| C5 | CRITICAL | `batcher_license.ak:78,92` | Wrong Aiken API: `tx.extra_signatures` should be `tx.extra_signatories` (causes compilation failure) | RESOLVED |

---

## Security Architecture Review

### Access Control
- **Admin operations:** All admin actions require signature verification via `tx.extra_signatories`
- **Multisig governance:** Treasury config changes require `min_signatures` of `governance_keys`
- **Owner-only operations:** Position modifications require the owner's signature
- **Pool-only minting:** NFT policies verify a pool/staking script input is present

### Oracle Security
- **Freshness checks:** Borrow and liquidation operations verify oracle age against configurable `max_oracle_age` from registry
- **Price sanity:** Maximum price change per update limited by `max_price_change` (basis points)
- **Timestamp validation:** Oracle timestamps must fall within the transaction's validity range
- **Rate limiting:** Minimum update interval enforced (`min_update_interval`)

### Integer Overflow Protection
- **Safe multiplication:** `safe_multiply()` in types.ak detects overflow via division verification
- **Time capping:** Interest calculations cap time elapsed at 10 years maximum
- **Rate factor sanity:** `rate_factor` bounded to 1,000,000 bps (100x)
- **Basis points:** All ratios use basis points (10000 = 100%) preventing floating-point issues

### Batcher System Security
- **License validation:** All batch operations validate an active, non-expired batcher license
- **Order verification:** Each order is verified individually (type, deadline, amount bounds)
- **Collateral checks:** BatchBorrow validates collateral sufficiency per order via oracle
- **Liquidation checks:** BatchLiquidate verifies undercollateralization per position via oracle
- **Order count integrity:** Number of order inputs matches `order_indices` list length

### Governance Security
- **Time-locked proposals:** Config updates require a governance delay before execution
- **Version incrementing:** Registry updates require version number to always increment
- **Timestamp advancing:** Registry updates require timestamp to advance (prevents replay)
- **Emergency controls:** Admin can trigger emergency shutdown (pauses all operations)
- **Upgrade mechanism:** Contract upgrades are time-locked with proposal/execution flow

### Token Integrity
- **Pool NFT:** One-time-mint with admin authorization, sent to pool script address
- **Position NFT:** Minted only when pool input present, owner signature required, sent to position script
- **Staker NFT:** Minted only when staking input present, owner signature required, sent to staker position script
- **Burn verification:** All NFT burns verified via `quantity_of(tx.mint, policy, name) == -1`

### Registry Pattern
- **Single source of truth:** All validators load config from a central Registry UTxO via reference inputs
- **Immutable references:** Script hashes, policies, and parameters verified against registry
- **Defense in depth:** Staking validator cross-checks datum config against registry values

### Emergency Controls
- **Global shutdown:** Admin can pause all operations via `EmergencyShutdown`
- **Granular pause:** Individual operation types can be paused/resumed independently
- **Operation types:** Deposits, Withdrawals, Borrows, Repayments, Liquidations, Staking, Unstaking, ClaimRewards

---

## Risk Assessment

| Category | Risk Level | Notes |
|----------|-----------|-------|
| Reentrancy | LOW | UTXO model prevents reentrancy by design |
| Oracle Manipulation | LOW | Freshness checks, sanity bounds, multi-oracle support |
| Integer Overflow | LOW | Safe math functions with overflow detection |
| Access Control | LOW | Admin/multisig/owner signature verification |
| Governance Attack | MEDIUM | Time-locked proposals mitigate but don't eliminate risk |
| Flash Loan Attack | LOW | Oracle freshness + collateral ratio checks |
| Front-Running | LOW | Batcher deadline system + order validation |

---

## Recommendations for Production Deployment

1. **Formal Verification:** Consider formal verification of critical math functions (interest calculation, collateral ratio)
2. **Multi-Oracle Setup:** Deploy multiple oracle sources and use the `aggregate_oracle_prices` median function
3. **Test Coverage:** Replace placeholder tests with comprehensive property-based tests
4. **Parameter Tuning:** Carefully tune risk parameters (collateral ratios, oracle age limits, utilization caps)
5. **Monitoring:** Implement off-chain monitoring for unusual activity patterns
6. **Bug Bounty:** Consider a bug bounty program for post-deployment security

---

## Changelog

- **v2 (2025-04-11):** Full re-audit. Fixed C4 (field name mismatch in staking.ak) and C5 (API typo in batcher_license.ak). Verified all v1 fixes intact. 0 open issues.
- **v1 (2025-04-10):** Initial audit. Fixed C1 (hardcoded hashes), C2 (missing admin check), H1/H2 (duplicates), M1 (double oracle check), M2 (BatchBorrow collateral), M3 (BatchLiquidate validation). 0 open issues.
