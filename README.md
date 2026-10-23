# Cardano Lending Protocol

# PLEASE NOTE THIS IS NOT A PRODUCTION READY CODE!!!

A full-featured lending protocol smart contract template for Cardano, written in [Aiken](https://aiken-lang.org/) and targeting Plutus V3.

Developed by [grae.one](https://grae.one)

## Overview

This protocol implements a complete lending pool system with:

- **Lending Pool** — Deposit, withdraw, borrow, repay, and liquidate operations
- **Staking** — Stake governance tokens to earn ADA and governance token rewards
- **Oracle** — Price feed management with multi-oracle median aggregation
- **Treasury** — Fee collection and distribution to LPs, stakers, and protocol
- **Batcher System** — Orderbook-based batch transaction processing
- **Registry** — Centralized on-chain configuration with governance controls
- **Emergency Controls** — Global shutdown and granular operation pausing

## Architecture

### Registry Pattern

All validators load their configuration from a central **Registry UTxO** via reference inputs. This eliminates hardcoded contract addresses and enables runtime parameter updates through governance.

```
Registry UTxO (reference input)
    |
    +--> lending_pool  (deposits, borrows, liquidations)
    +--> staking       (stake, unstake, claim rewards)
    +--> treasury      (fee collection, distribution)
    +--> orderbook     (batcher orders)
    +--> oracle        (price feeds)
    +--> NFT policies  (pool, position, staker identity)
```

### Validators

| Validator | File | Description |
|-----------|------|-------------|
| `lending_pool` | `validators/lending_pool.ak` | Core pool with 16 redeemer actions |
| `staking` | `validators/staking.ak` | Governance token staking with rewards |
| `oracle` | `validators/oracle.ak` | Price feed with sanity checks |
| `treasury` | `validators/treasury.ak` | Fee management with multisig governance |
| `position` | `validators/position.ak` | Borrower position state |
| `staker_position` | `validators/staker_position.ak` | Staker position state |
| `registry` | `validators/registry.ak` | Central configuration management |
| `orderbook` | `validators/orderbook.ak` | Batcher order queue |
| `pool_nft` | `validators/pool_nft.ak` | Pool identity NFT (one-time-mint) |
| `position_nft` | `validators/position_nft.ak` | Position identity NFT |
| `staker_nft` | `validators/staker_nft.ak` | Staker identity NFT |
| `batcher_license` | `validators/batcher_license.ak` | Batcher access control |

### Library Modules

| Module | File | Description |
|--------|------|-------------|
| `lending/types` | `lib/types.ak` | All shared types and math functions |
| `lending/helpers` | `lib/helpers.ak` | Utility functions (signature, oracle, time) |
| `lending/registry_helpers` | `lib/registry_helpers.ak` | Registry loading and validation |

## Operations

### Lending Pool Operations

#### Direct Operations
- **Deposit** — Deposit lend asset, receive position tracking
- **Withdraw** — Withdraw deposited asset from position
- **Borrow** — Borrow against collateral with oracle price verification
- **Repay** — Repay debt with accrued interest
- **Liquidate** — Liquidate undercollateralized positions

#### Batch Operations (Batcher)
- **BatchDeposit** — Process multiple deposits in one transaction
- **BatchWithdraw** — Process multiple withdrawals in one transaction
- **BatchBorrow** — Process multiple borrows with per-order oracle validation
- **BatchRepay** — Process multiple repayments in one transaction
- **BatchLiquidate** — Process multiple liquidations with per-position verification

#### Governance
- **ProposeConfigUpdate** — Propose pool config change (time-locked)
- **ExecuteConfigUpdate** — Execute after governance delay
- **CancelConfigUpdate** — Cancel pending proposal

### Staking Operations
- **Stake** — Lock governance tokens to earn rewards
- **Unstake** — Withdraw staked tokens (after minimum period)
- **ClaimRewards** — Claim accumulated ADA and token rewards
- **DistributeRewards** — Add rewards to pool (from treasury/pool)

### Registry Operations
- **UpdateRegistry** — Direct admin update (version increment required)
- **ProposeUpdate / ExecuteUpdate / CancelUpdate** — Time-locked governance
- **EmergencyShutdown / ResumeOperations** — Global emergency controls
- **PauseOperation / ResumeOperation** — Granular operation pausing
- **ProposeUpgrade / ExecuteUpgrade / CancelUpgrade** — Contract upgrade flow

## Key Types

### PoolConfig
```aiken
PoolConfig {
  asset_lend: AssetClass,
  asset_collateral: AssetClass,
  collateral_ratio: Int,          // basis points (e.g., 15000 = 150%)
  liquidation_threshold: Int,     // basis points
  liquidation_penalty: Int,       // basis points
  base_rate: Int,                 // basis points
  slope1: Int, slope2: Int,       // interest rate model
  optimal_utilization: Int,       // basis points
  max_oracle_age_borrow: Int,     // milliseconds
  max_oracle_age_liquidate: Int,  // milliseconds
  // ... script hashes, governance
}
```

### RegistryDatum
```aiken
RegistryDatum {
  // Contract hashes
  lending_pool_hash, orderbook_hash, position_hash,
  staking_hash, treasury_hash, oracle_hash: ByteArray,
  // NFT policies
  pool_nft_policy, position_nft_policy, staker_nft_policy, batcher_license_policy: ByteArray,
  // Risk parameters
  max_borrow_rate_bps, min_collateral_ratio_bps, max_utilization_rate_bps: Int,
  // Amount limits
  min_deposit_amount, min_borrow_amount, max_single_deposit, max_single_borrow: Int,
  // Fee distribution (must sum to 10000)
  protocol_fee_bps, treasury_share_bps, staking_share_bps, lp_share_bps: Int,
  // Governance
  admin_pkh: ByteArray,
  governance_delay: Int,          // milliseconds
  emergency_shutdown: Bool,
  paused_operations: List<Operation>,
  // ... versioning, upgrades
}
```

## Interest Rate Model

Uses a two-slope model (similar to Aave):

```
Below optimal utilization: rate = base_rate + utilization * slope1
Above optimal utilization: rate = base_rate + optimal * slope1 + excess * slope2
```

All rates are in basis points where 10000 = 100%.

## Security Features

- **Oracle freshness** — Configurable max age for borrow and liquidation operations
- **Price sanity bounds** — Maximum price change per update (basis points)
- **Collateral verification** — Per-order oracle-based collateral checks in batch operations
- **Integer overflow protection** — Safe multiplication with overflow detection
- **Time-locked governance** — All major changes require a delay before execution
- **Multisig treasury** — Fee distribution changes require minimum signature threshold
- **Emergency controls** — Admin can pause all or specific operations
- **NFT authentication** — Parameterized minting policies with admin/owner verification
- **Registry defense-in-depth** — Validators cross-check datum config against immutable registry

See [SECURITY.md](SECURITY.md) for the full audit report.

## Prerequisites

- [Aiken](https://aiken-lang.org/) v1.1.19 or compatible
- Cardano node (for deployment)

## Building

```bash
# Clone the repository
git clone https://github.com/G1xHub/cardano-pool-lending-community-eco.git
cd cardano-pool-lending-community-eco/contracts

# Build the project
aiken build

# Run checks (tests)
aiken check
```

## Project Structure

```
contracts/
├── aiken.toml              # Package configuration
├── aiken.lock              # Dependency lockfile
├── lib/
│   ├── types.ak            # Core types and math functions
│   ├── helpers.ak          # Shared utility functions
│   └── registry_helpers.ak # Registry loading and validation
├── validators/
│   ├── lending_pool.ak     # Core lending pool
│   ├── staking.ak          # Staking contract
│   ├── oracle.ak           # Oracle price feed
│   ├── treasury.ak         # Treasury and fee management
│   ├── position.ak         # Borrower position state
│   ├── staker_position.ak  # Staker position state
│   ├── registry.ak         # Central configuration
│   ├── orderbook.ak        # Batcher order queue
│   ├── pool_nft.ak         # Pool NFT minting policy
│   ├── position_nft.ak     # Position NFT minting policy
│   ├── staker_nft.ak       # Staker NFT minting policy
│   └── batcher_license.ak  # Batcher license policy
├── build/                  # Compiled Plutus scripts (gitignored)
├── LICENSE                 # Apache-2.0
├── README.md               # This file
└── SECURITY.md             # Security audit report
```

## Parameterization

All validators that need external references are parameterized:

- `lending_pool(LendingPoolParams { registry_script_hash })` 
- `staking(StakingParams { registry_script_hash })`
- `treasury(TreasuryParams { registry_script_hash })`
- `orderbook(OrderbookParams { registry_script_hash })`
- `oracle(OracleParams { authorized_updaters, min_update_interval, max_price_change })`
- `pool_nft(PoolNftParams { admin_pkh, pool_script_hash })`
- `position_nft(PositionNftParams { pool_script_hash, position_script_hash })`
- `staker_nft(StakerNftParams { staking_script_hash, staker_position_script_hash })`
- `batcher_license(BatcherLicenseParams { admin_pkh, pool_id })`
- `position` — Stateless (no parameters)
- `staker_position` — Stateless (no parameters)
- `registry` — Stateless (no parameters)

## Deployment Notes

1. Deploy the registry validator first (no dependencies)
2. Deploy oracle with authorized updater keys
3. Deploy NFT policies with appropriate script hashes
4. Deploy lending_pool, staking, treasury with registry hash
5. Initialize the Registry UTxO with all contract hashes and policies
6. Create pool UTxO with pool NFT and initial PoolDatum

## License

Apache-2.0 — See [LICENSE](LICENSE) for details.

## Disclaimer

This is a template provided as-is for educational and development purposes. It has undergone ai driven security auditing but has not been formally verified. Use at your own risk. Always conduct your own security review before deploying to mainnet.
