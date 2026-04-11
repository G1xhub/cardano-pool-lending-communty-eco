// Cardano Lending Protocol - Core Types and Calculations
// Developed by grae.one (utxotools.io)
//
// Version: 8.0.0 - Registry Pattern Migration
// License: Apache-2.0
//
// This module defines all shared data types, redeemer types, and
// mathematical calculation functions used across the Lending Protocol.
// All validators depend on these type definitions for datum parsing
// and redeemer dispatch.

use cardano/assets.{PolicyId}
use cardano/transaction.{OutputReference}

// =============================================================================
// SECTION: Asset Types
// =============================================================================

/// Represents a Cardano native asset by its policy ID and asset name.
/// An empty policy_id and asset_name represents ADA (lovelace).
pub type AssetClass {
  policy_id: PolicyId,
  asset_name: ByteArray,
}

// =============================================================================
// SECTION: Pool Configuration and State
// =============================================================================

/// Immutable-per-pool configuration parameters.
/// Changes require governance approval via ProposeConfigUpdate/ExecuteConfigUpdate.
pub type PoolConfig {
  /// The asset being lent out to borrowers (e.g., ADA or a stablecoin)
  asset_lend: AssetClass,
  /// The asset accepted as collateral (e.g., BTC, ETH, or native tokens)
  asset_collateral: AssetClass,
  /// Required collateral ratio in basis points (e.g., 15000 = 150%)
  collateral_ratio: Int,
  /// Threshold below which liquidation is triggered (e.g., 12000 = 120%)
  liquidation_threshold: Int,
  /// Penalty applied during liquidation in basis points (e.g., 500 = 5%)
  liquidation_penalty: Int,
  /// Base interest rate when utilization is 0 (basis points)
  base_rate: Int,
  /// Interest rate slope below optimal utilization (basis points)
  slope1: Int,
  /// Interest rate slope above optimal utilization (basis points)
  slope2: Int,
  /// Optimal utilization target in basis points (e.g., 8000 = 80%)
  optimal_utilization: Int,
  /// Script hash of the treasury contract for fee distribution
  treasury_script_hash: ByteArray,
  /// Script hash of the staking contract for reward distribution
  staking_script_hash: ByteArray,
  /// Script hash of the position contract for borrower positions
  position_script_hash: ByteArray,
  /// Maximum allowed oracle age for borrow operations (milliseconds)
  max_oracle_age_borrow: Int,
  /// Maximum allowed oracle age for liquidation operations (milliseconds)
  max_oracle_age_liquidate: Int,
  /// Script hash of the governance contract authorized to propose config changes
  governance_script_hash: ByteArray,
  /// Pending configuration update awaiting time-locked activation
  pending_config: Option<PoolConfig>,
  /// Timestamp when the pending config becomes executable (milliseconds)
  config_activation_time: Option<Int>,
}

/// On-chain state of a lending pool, stored as the UTxO datum.
pub type PoolDatum {
  /// Pool configuration parameters
  config: PoolConfig,
  /// Total amount of the lend asset currently deposited
  total_deposited: Int,
  /// Total amount of the lend asset currently borrowed
  total_borrowed: Int,
  /// Reference to the oracle UTxO for price data
  oracle_ref: OutputReference,
}

// =============================================================================
// SECTION: Position Types (Borrower Positions)
// =============================================================================

/// Represents a single borrower's position in a lending pool.
pub type PositionDatum {
  /// Owner's payment public key hash (identifies the position holder)
  owner: ByteArray,
  /// Amount of the lend asset deposited as liquidity
  deposited: Int,
  /// Amount of the lend asset currently borrowed
  borrowed: Int,
  /// Amount of collateral asset locked
  collateral: Int,
  /// Timestamp when the borrow was initiated (milliseconds)
  borrow_timestamp: Int,
  /// Timestamp of the last interest accrual update (milliseconds)
  last_interest_update: Int,
}

// =============================================================================
// SECTION: Oracle Types
// =============================================================================

/// Price feed data from an authorized oracle source.
pub type OracleData {
  /// Current asset price (in the oracle's defined units)
  price: Int,
  /// Timestamp of the price update (milliseconds since epoch)
  timestamp: Int,
  /// Identifier of the oracle source (for multi-oracle setups)
  source: ByteArray,
}

/// Redeemer for oracle price updates.
pub type OracleRedeemer {
  UpdatePrice { new_price: Int, new_timestamp: Int }
}

// =============================================================================
// SECTION: Pool Redeemers
// =============================================================================

/// All possible actions that can be performed on the lending pool.
pub type PoolRedeemer {
  // --- Direct User Operations ---

  /// Deposit lend asset into the pool to earn interest
  Deposit { amount: Int }

  /// Withdraw previously deposited lend asset
  Withdraw { amount: Int, position_ref: OutputReference }

  /// Borrow lend asset against collateral
  Borrow {
    amount: Int,
    collateral_amount: Int,
    position_ref: OutputReference,
  }

  /// Repay borrowed asset plus accrued interest
  Repay { amount: Int, position_ref: OutputReference }

  /// Liquidate an undercollateralized position
  Liquidate { position_ref: OutputReference }

  // --- Batched Operations (Batcher System) ---

  /// Process multiple deposit orders in a single transaction
  /// order_indices: (order_input_idx, position_output_idx)
  BatchDeposit { license_idx: Int, order_indices: List<(Int, Int)> }

  /// Process multiple withdraw orders in a single transaction
  /// order_indices: (order_input_idx, position_input_idx)
  BatchWithdraw { license_idx: Int, order_indices: List<(Int, Int)> }

  /// Process multiple borrow orders in a single transaction
  /// order_indices: (order_idx, position_idx, oracle_idx)
  BatchBorrow { license_idx: Int, order_indices: List<(Int, Int, Int)> }

  /// Process multiple repay orders in a single transaction
  /// order_indices: (order_input_idx, position_input_idx)
  BatchRepay { license_idx: Int, order_indices: List<(Int, Int)> }

  /// Process multiple liquidation orders in a single transaction
  /// order_indices: (order_input_idx, position_input_idx)
  BatchLiquidate { license_idx: Int, order_indices: List<(Int, Int)> }

  // --- Governance Operations ---

  /// Propose a new pool configuration (time-locked)
  ProposeConfigUpdate { new_config: PoolConfig }

  /// Execute a previously proposed configuration after delay
  ExecuteConfigUpdate

  /// Cancel a pending configuration proposal
  CancelConfigUpdate
}

// =============================================================================
// SECTION: Position Redeemers
// =============================================================================

/// Actions that can be performed on a borrower position.
pub type PositionRedeemer {
  /// Update the deposit amount (increase or decrease)
  UpdateDeposit { amount_change: Int, pool_ref: OutputReference }

  /// Update borrow amount and/or collateral amount
  UpdateBorrow {
    amount_change: Int,
    collateral_change: Int,
    pool_ref: OutputReference,
  }

  /// Repay borrowed amount, reducing debt
  RepayPosition { amount: Int, pool_ref: OutputReference }

  /// Close the position entirely (requires zero debt)
  Close { pool_ref: OutputReference }
}

// =============================================================================
// SECTION: Order Types (Batcher System)
// =============================================================================

/// Order datum variants for the batcher/orderbook system.
/// Each order type represents a user's intent queued for batch processing.
pub type OrderDatum {
  /// Deposit order: user wants to deposit lend asset
  ODeposit { owner: ByteArray, amount: Int, batcher_fee: Int, deadline: Int }

  /// Withdraw order: user wants to withdraw deposited asset
  OWithdraw {
    owner: ByteArray,
    amount: Int,
    position_ref: OutputReference,
    batcher_fee: Int,
    deadline: Int,
  }

  /// Borrow order: user wants to borrow against collateral
  OBorrow {
    owner: ByteArray,
    amount: Int,
    collateral_amount: Int,
    position_ref: OutputReference,
    batcher_fee: Int,
    deadline: Int,
  }

  /// Repay order: user wants to repay borrowed amount
  ORepay {
    owner: ByteArray,
    amount: Int,
    position_ref: OutputReference,
    batcher_fee: Int,
    deadline: Int,
  }

  /// Liquidation order: trigger liquidation of an undercollateralized position
  OLiquidate {
    owner: ByteArray,
    position_ref: OutputReference,
    batcher_fee: Int,
    deadline: Int,
  }
}

// =============================================================================
// SECTION: Staking Types
// =============================================================================

/// Global staking contract state stored as UTxO datum.
pub type StakingDatum {
  /// Total amount of staking tokens currently staked
  total_staked: Int,
  /// Accumulated reward per staked token (for APY calculation)
  reward_per_token: Int,
  /// Timestamp of the last global reward update
  last_update_time: Int,
  /// Timestamp of the last reward distribution event
  last_reward_distribution: Int,
  /// Available ADA rewards pool (from protocol fees)
  ada_rewards_pool: Int,
  /// Available governance token rewards pool
  staking_rewards_pool: Int,
  /// Staking configuration parameters
  config: StakingConfig,
}

/// Staking pool configuration.
pub type StakingConfig {
  /// The token that must be staked (governance token)
  staking_token: AssetClass,
  /// The token distributed as rewards
  reward_token: AssetClass,
  /// Minimum amount required to open a stake position
  min_stake_amount: Int,
  /// Minimum time before unstaking is allowed (milliseconds)
  min_stake_period: Int,
  /// Additional delay after unstake request before withdrawal
  unstake_delay: Int,
}

/// Individual staker's position state.
pub type StakerPosition {
  /// Owner's payment public key hash
  owner: ByteArray,
  /// Amount of staking tokens currently staked
  staked_amount: Int,
  /// Accumulated reward debt (for pending reward calculation)
  reward_debt: Int,
  /// Timestamp when staking was initiated
  stake_timestamp: Int,
  /// Timestamp of last reward claim
  last_claim_time: Int,
  /// Total ADA rewards already claimed
  ada_rewards_claimed: Int,
  /// Total governance token rewards already claimed
  staking_rewards_claimed: Int,
}

/// Redeemer actions for the staking contract.
pub type StakingRedeemer {
  /// Stake tokens to earn rewards
  Stake { amount: Int }
  /// Unstake tokens (after minimum stake period)
  Unstake { amount: Int }
  /// Claim accumulated rewards
  ClaimRewards
  /// Distribute new rewards (called by treasury or pool)
  DistributeRewards { ada_amount: Int, reward_amount: Int }
}

/// Redeemer actions for individual staker positions.
pub type StakerPositionRedeemer {
  /// Update position after staking more tokens
  UpdateStake { amount: Int, staking_ref: OutputReference }
  /// Update position after unstaking tokens
  UpdateUnstake { amount: Int, staking_ref: OutputReference }
  /// Update position after claiming rewards
  UpdateClaimRewards { staking_ref: OutputReference }
  /// Close the staker position entirely
  CloseStakerPosition { staking_ref: OutputReference }
}

// =============================================================================
// SECTION: Treasury Types
// =============================================================================

/// Identifies which protocol contract a fee originates from.
pub type ContractType {
  Pool
  Staking
}

/// Treasury contract state for managing protocol fees.
pub type TreasuryDatum {
  /// List of governance public key hashes authorized to manage treasury
  governance_keys: List<ByteArray>,
  /// Minimum number of signatures required for governance actions
  min_signatures: Int,
  /// Current ADA balance held by the treasury
  ada_balance: Int,
  /// Current governance token balance held by the treasury
  reward_token_balance: Int,
  /// Balances of other tokens held by the treasury
  token_balances: List<(AssetClass, Int)>,
  /// Total ADA distributed since protocol inception
  total_ada_distributed: Int,
  /// Total governance tokens distributed since protocol inception
  total_reward_tokens_distributed: Int,
  /// Fee distribution configuration (ratios for LPs, stakers, protocol)
  fee_distribution: FeeDistribution,
  /// Timestamp of the last fee distribution
  last_distribution: Int,
}

/// Redeemer actions for the treasury contract.
pub type TreasuryRedeemer {
  /// Collect fees from a protocol contract (pool or staking)
  CollectFees {
    fee_type: FeeType,
    amount: Int,
    asset: AssetClass,
    from_contract: ContractType,
  }
  /// Distribute collected fees to LPs, stakers, and protocol
  DistributeFees { asset: AssetClass, amount_to_distribute: Int }
  /// Update the fee distribution ratios (requires multisig)
  UpdateConfig { new_distribution: FeeDistribution }
  /// Withdraw protocol's share of fees (requires multisig)
  WithdrawProtocol { asset: AssetClass, amount: Int }
}

/// Categories of protocol fees.
pub type FeeType {
  RepayInterest
  LiquidationPenalty
}

/// Fee distribution ratios in basis points. Must sum to 10000 (100%).
pub type FeeDistribution {
  /// Share of fees allocated to liquidity providers
  lp_ratio: Int,
  /// Share of fees allocated to stakers
  staker_ratio: Int,
  /// Share of fees retained by the protocol treasury
  protocol_ratio: Int,
}

// =============================================================================
// SECTION: Registry Types (Central Configuration)
// =============================================================================

/// Central registry datum - single source of truth for all protocol configuration.
/// All validators reference this via reference inputs to obtain their configuration.
pub type RegistryDatum {
  // --- Contract Script Hashes ---
  /// Script hash of the lending pool validator
  lending_pool_hash: ByteArray,
  /// Script hash of the orderbook validator
  orderbook_hash: ByteArray,
  /// Script hash of the position validator
  position_hash: ByteArray,
  /// Script hash of the staking validator
  staking_hash: ByteArray,
  /// Script hash of the treasury validator
  treasury_hash: ByteArray,
  /// Script hash of the oracle validator
  oracle_hash: ByteArray,

  // --- Minting Policy IDs ---
  /// Policy ID for pool NFT minting
  pool_nft_policy: ByteArray,
  /// Policy ID for position NFT minting
  position_nft_policy: ByteArray,
  /// Policy ID for staker NFT minting
  staker_nft_policy: ByteArray,
  /// Policy ID for batcher license minting
  batcher_license_policy: ByteArray,

  // --- Pool NFT Configuration ---
  /// Token name for the pool identity NFT
  pool_nft_name: ByteArray,

  // --- Verified Token Policies ---
  /// Policy ID of the governance/staking token
  staking_token_policy: ByteArray,
  /// Token name of the governance/staking token
  staking_token_name: ByteArray,
  /// Policy ID for pool-specific tokens
  pool_token_policy: ByteArray,
  /// Token name for pool-specific tokens
  pool_token_name: ByteArray,

  // --- Protocol Fee Parameters (basis points) ---
  /// Protocol-wide fee in basis points
  protocol_fee_bps: Int,
  /// Treasury's share of fees in basis points
  treasury_share_bps: Int,
  /// Stakers' share of fees in basis points
  staking_share_bps: Int,
  /// Liquidity providers' share of fees in basis points
  lp_share_bps: Int,

  // --- Risk Parameters ---
  /// Maximum allowed borrow rate in basis points
  max_borrow_rate_bps: Int,
  /// Minimum collateral ratio in basis points
  min_collateral_ratio_bps: Int,
  /// Maximum pool utilization rate in basis points
  max_utilization_rate_bps: Int,

  // --- Operational Amount Limits ---
  /// Minimum deposit amount (smallest unit)
  min_deposit_amount: Int,
  /// Minimum borrow amount (smallest unit)
  min_borrow_amount: Int,
  /// Maximum single deposit amount
  max_single_deposit: Int,
  /// Maximum single borrow amount
  max_single_borrow: Int,

  // --- Time Parameters (milliseconds) ---
  /// Maximum oracle age for borrow operations
  max_oracle_age_borrow: Int,
  /// Maximum oracle age for liquidation operations
  max_oracle_age_liquidate: Int,
  /// Buffer time added to batcher order deadlines
  batcher_deadline_buffer: Int,

  // --- Governance ---
  /// Admin's payment public key hash
  admin_pkh: ByteArray,
  /// Time delay for governance proposals before execution (milliseconds)
  governance_delay: Int,
  /// Pending governance update awaiting execution
  pending_update: Option<PendingUpdate>,

  // --- Emergency Controls ---
  /// Whether the protocol is in emergency shutdown mode
  emergency_shutdown: Bool,
  /// List of currently paused operation types
  paused_operations: List<Operation>,

  // --- Versioning & Metadata ---
  /// Protocol version number (incremented on each update)
  version: Int,
  /// Timestamp of the last registry update
  last_updated: Int,
  /// Pending contract upgrade proposal
  upgrade_proposal: Option<UpgradeProposal>,
}

/// A pending governance update with time-locked execution.
pub type PendingUpdate {
  /// The new registry datum to apply
  new_datum: RegistryDatum,
  /// Timestamp when the update was proposed
  proposed_at: Int,
  /// Timestamp when the update can be executed
  activation_time: Int,
}

/// A pending contract upgrade proposal.
pub type UpgradeProposal {
  /// List of (contract_name_hash, new_script_hash) pairs to upgrade
  new_contract_hashes: List<(ByteArray, ByteArray)>,
  /// Timestamp when the upgrade was proposed
  proposed_at: Int,
  /// Timestamp when the upgrade can be executed
  execution_time: Int,
  /// Proposer's public key hash
  proposer: ByteArray,
}

/// Operations that can be individually paused/resumed.
pub type Operation {
  Deposits
  Withdrawals
  Borrows
  Repayments
  Liquidations
  StakingOp
  Unstaking
  ClaimRewardsOp
}

/// Redeemer actions for the registry contract.
pub type RegistryRedeemer {
  // --- Admin Operations ---
  /// Direct registry update by admin (for minor changes, version increment required)
  UpdateRegistry { new_datum: RegistryDatum }
  /// Propose a time-locked registry update (for major changes)
  ProposeUpdate { new_datum: RegistryDatum }
  /// Execute a previously proposed update after governance delay
  ExecuteUpdate
  /// Cancel a pending update proposal
  CancelUpdate

  // --- Emergency Operations ---
  /// Trigger emergency shutdown (pauses all operations)
  EmergencyShutdown
  /// Resume all operations after emergency shutdown
  ResumeOperations
  /// Pause a specific operation type
  PauseOperation { operation: Operation }
  /// Resume a specific paused operation type
  ResumeOperation { operation: Operation }

  // --- Upgrade Management ---
  /// Propose a contract upgrade (time-locked)
  ProposeUpgrade { new_hashes: List<(ByteArray, ByteArray)> }
  /// Execute a proposed contract upgrade after delay
  ExecuteUpgrade
  /// Cancel a proposed contract upgrade
  CancelUpgrade

  // --- Read-only ---
  /// Read registry data (always succeeds, used for reference inputs)
  ReadRegistry
}

// =============================================================================
// SECTION: Mathematical Calculation Functions
// =============================================================================
//
// All calculations use basis points (bps) where 10000 = 100%.
// Overflow protection is applied to prevent integer overflow attacks.

/// Safe multiplication with overflow detection.
/// Verifies the result by checking that result / a == b (overflow wraparound detection).
pub fn safe_multiply(a: Int, b: Int) -> Int {
  let result = a * b

  if a == 0 || result / a == b {
    result
  } else {
    fail @"Integer overflow in multiplication"
  }
}

/// Calculate interest accrued on a principal amount.
///
/// Uses division-before-multiplication to prevent overflow:
///   interest = principal * (rate * time / year) / 10000
///
/// Time is capped at 10 years maximum to prevent absurd values.
pub fn calculate_interest(
  principal: Int,
  annual_rate: Int,
  time_elapsed_ms: Int,
) -> Int {
  let year_in_ms = 31_536_000_000
  let max_time = 315_360_000_000

  let capped_time =
    if time_elapsed_ms > max_time {
      max_time
    } else {
      time_elapsed_ms
    }

  // Divide first to keep intermediate values small
  let rate_factor = annual_rate * capped_time / year_in_ms

  // Sanity check: rate_factor should not exceed 1,000,000 bps (100x)
  expect rate_factor <= 1_000_000

  principal * rate_factor / 10000
}

/// Extra-safe interest calculation with step-by-step overflow checks.
/// Use this for critical operations where maximum safety is required.
/// Each intermediate multiplication is individually overflow-checked.
pub fn calculate_interest_extra_safe(
  principal: Int,
  annual_rate: Int,
  time_elapsed_ms: Int,
) -> Int {
  let year_in_ms = 31_536_000_000
  let max_time = 315_360_000_000

  let capped_time =
    if time_elapsed_ms > max_time {
      max_time
    } else {
      time_elapsed_ms
    }

  let temp1 = safe_multiply(annual_rate, capped_time)
  let temp2 = temp1 / year_in_ms
  let temp3 = safe_multiply(principal, temp2)
  temp3 / 10000
}

/// Calculate the dynamic borrow interest rate based on pool utilization.
///
/// Uses a two-slope model (similar to Aave):
///   - Below optimal utilization: rate = base_rate + utilization * slope1
///   - Above optimal utilization: rate = base_rate + optimal * slope1 + excess * slope2
///
/// All rates in basis points (10000 = 100%).
pub fn calculate_dynamic_borrow_rate(
  total_borrowed: Int,
  total_deposited: Int,
  base_rate: Int,
  slope1: Int,
  slope2: Int,
  optimal_utilization: Int,
) -> Int {
  if total_deposited == 0 {
    base_rate
  } else {
    let utilization = total_borrowed * 10000 / total_deposited
    if utilization <= optimal_utilization {
      base_rate + utilization * slope1 / 10000
    } else {
      let rate_at_optimal = base_rate + optimal_utilization * slope1 / 10000
      let excess_utilization = utilization - optimal_utilization
      rate_at_optimal + excess_utilization * slope2 / 10000
    }
  }
}

/// Calculate the required collateral amount for a given borrow.
///
/// Formula: borrow_amount * collateral_ratio * oracle_price / 10000 / 1_000_000
/// The oracle_price is assumed to be in units where 1_000_000 = 1 full unit.
pub fn calculate_required_collateral(
  borrow_amount: Int,
  oracle_price: Int,
  collateral_ratio: Int,
) -> Int {
  borrow_amount * collateral_ratio * oracle_price / 10000 / 1_000_000
}

/// Determine if a position is undercollateralized and eligible for liquidation.
///
/// Compares the effective collateral value against the required collateral
/// based on the liquidation threshold.
pub fn is_undercollateralized(
  borrowed: Int,
  collateral: Int,
  oracle_price: Int,
  liquidation_threshold: Int,
) -> Bool {
  let collateral_value = collateral * 1_000_000 / oracle_price
  let required_collateral = borrowed * liquidation_threshold / 10000
  collateral_value < required_collateral
}

/// Distribute a liquidation penalty across protocol stakeholders.
///
/// Returns (lp_share, staker_share, treasury_share) as a tuple.
/// Default distribution: 75% LPs, 15% stakers, 10% treasury.
pub fn calculate_penalty_distribution(penalty_amount: Int) -> (Int, Int, Int) {
  let lp_share = penalty_amount * 75 / 100
  let staker_share = penalty_amount * 15 / 100
  let treasury_share = penalty_amount * 10 / 100
  (lp_share, staker_share, treasury_share)
}
