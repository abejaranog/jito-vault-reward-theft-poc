# Attack Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    JITO RESTAKING VAULT STATE TIMELINE                  │
└─────────────────────────────────────────────────────────────────────────┘

TIME: T0 (Before Epoch Update)
┌──────────────────────────────────────────┐
│ Vault State:                             │
│  tokens_deposited = 1,000,000 SOL        │
│  vrt_supply       = 1,000,000 VRT        │
│  actual_balance   = 1,000,000 SOL        │
│  Exchange rate    = 1.0 token/VRT        │
└──────────────────────────────────────────┘
                    │
                    │ Staking rewards accrue
                    ▼
TIME: T1 (Rewards Accrued, Before Epoch Update)
┌──────────────────────────────────────────┐
│ Vault Token Account:                     │
│  actual_balance   = 1,100,000 SOL ✨     │
│                     (100K rewards)       │
│                                          │
│ Vault Internal State (STALE):           │
│  tokens_deposited = 1,000,000 SOL        │
│  vrt_supply       = 1,000,000 VRT        │
└──────────────────────────────────────────┘
                    │
                    │ Epoch boundary passes
                    ▼
TIME: T2 (Epoch Update Cycle)
┌──────────────────────────────────────────┐
│ 1. InitializeVaultUpdateStateTracker     │
│ 2. CrankVaultUpdateStateTracker (x N)    │
│ 3. CloseVaultUpdateStateTracker          │
│                                          │
│ ✅ check_update_state_ok() NOW PASSES   │
└──────────────────────────────────────────┘
                    │
                    │ ⚠️ VULNERABILITY WINDOW OPENS
                    ▼
        ┌───────────────────────────┐
        │  RACE CONDITION ZONE      │
        │  Both instructions valid: │
        │  - MintTo                 │
        │  - UpdateVaultBalance     │
        └───────────────────────────┘
                    │
        ┌───────────┴───────────┐
        │                       │
        ▼                       ▼
   🚨 ATTACK PATH          NORMAL PATH
        │                       │
        │                       │
TIME: T3a (Attacker Front-Runs)   TIME: T3b (Honest Flow)
┌──────────────────────────┐     ┌──────────────────────────┐
│ Attacker calls MintTo    │     │ UpdateVaultBalance       │
│ with 10,000,000 SOL      │     │ called FIRST             │
│                          │     │                          │
│ VRT minted:              │     │ Reconciles balance:      │
│ = 10M * 1M / 1M          │     │ tokens_deposited = 1.1M  │
│ = 10,000,000 VRT         │     │ vrt_supply ≈ 1,009,918   │
│                          │     │ (after reward fee)       │
│ Rate used: 1.0 ❌        │     │                          │
│ Should be: 1.1 ✅        │     │ Rate: 1.0892 ✅          │
└──────────────────────────┘     └──────────────────────────┘
        │                               │
        │                               │
        ▼                               ▼
TIME: T4a (After Attack)        TIME: T4b (Honest Result)
┌──────────────────────────┐     ┌──────────────────────────┐
│ UpdateVaultBalance runs  │     │ User deposits 10M SOL    │
│                          │     │                          │
│ Rewards = 1.1M - 11M     │     │ VRT minted:              │
│         = 100K SOL       │     │ = 10M * 1,009,918 / 1.1M │
│                          │     │ ≈ 9,181,072 VRT          │
│ Final state:             │     │                          │
│ tokens_deposited = 11.1M │     │ Fair exchange rate! ✅   │
│ vrt_supply ≈ 11,009,918  │     │                          │
│ Rate ≈ 1.00818           │     └──────────────────────────┘
│                          │
│ Attacker's 10M VRT worth:│
│ = 10M * 1.00818          │
│ ≈ 10,081,800 SOL         │
│                          │
│ PROFIT: ~81,800 SOL 💰   │
└──────────────────────────┘
        │
        ▼
TIME: T5 (Impact on Original Depositors)
┌──────────────────────────────────────────┐
│ Original depositors' 1M VRT:             │
│                                          │
│ WITHOUT attack: 1M * 1.0892 = 1,089,200  │
│ WITH attack:    1M * 1.00818 = 1,008,180 │
│                                          │
│ LOSS: ~81,000 SOL ❌                     │
│                                          │
│ (Stolen by attacker via reward dilution) │
└──────────────────────────────────────────┘
```

## Key Vulnerability Points

### 1. Missing Ordering Enforcement
```rust
// vault_program/src/mint_to.rs:74
vault.check_update_state_ok(Clock::get()?.slot, config.epoch_length())?;

// vault_program/src/update_vault_balance.rs:36
vault.check_update_state_ok(Clock::get()?.slot, config.epoch_length())?;
```
**Both use the same check — no enforcement that UpdateVaultBalance must run first!**

### 2. Stale Exchange Rate Calculation
```rust
// vault_core/src/vault.rs:930-943
pub fn calculate_vrt_mint_amount(&self, amount_in: u64) -> Result<u64, VaultError> {
    let amount = (amount_in as u128)
        .checked_mul(self.vrt_supply() as u128)
        .and_then(|x| x.checked_div(self.tokens_deposited() as u128))  // ⚠️ STALE
        .and_then(|x| x.try_into().ok())
        .ok_or(VaultError::VaultOverflow)?;
    Ok(amount)
}
```

### 3. Reward Calculation After Attack
```rust
// vault_program/src/update_vault_balance.rs:47
let st_rewards = new_st_balance.saturating_sub(vault.tokens_deposited());
// ⚠️ If attacker already deposited, this only captures original rewards
```

## Profit Formula

```
attacker_profit = rewards × (attacker_deposit / (total_deposits + attacker_deposit))
                  - deposit_fee - withdrawal_fee

With 0% fees:
profit = 100,000 × (10,000,000 / 11,000,000)
       ≈ 81,818 SOL
```

## Mitigation

Add a flag to enforce ordering:

```rust
pub struct Vault {
    // ... existing fields ...
    balance_updated_this_epoch: bool,  // ← NEW
}

// In CloseVaultUpdateStateTracker:
vault.balance_updated_this_epoch = false;

// In UpdateVaultBalance:
vault.balance_updated_this_epoch = true;

// In MintTo:
if !vault.balance_updated_this_epoch {
    return Err(VaultError::VaultBalanceNotUpdated.into());
}
```
