# MetaYield - Autonomous Yield Engine Architecture

**Built for the BNB Chain Good Vibes Only Hackathon**

## 🚀 Philosophy: Self-Driving, Permissionless, Immutable

MetaYield is a **fully autonomous** yield optimization protocol. No admin keys, no owner, no pause button. Anyone can trigger protocol cycles.

## 📐 Modular Architecture

```
┌─────────────────┐
│   MetaVault     │  ← ERC4626 vault (deposits/withdrawals only)
│   (MYV token)   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   EngineCore    │  ← Permissionless orchestrator
│   executeCycle  │     Callable by ANYONE
│   (1hr cooldown)│
└────────┬────────┘
         │
         ├──────────────────┐
         │                  │
         ▼                  ▼
┌─────────────────┐   ┌──────────────┐
│ StrategyRouter  │   │ VolatilityLib│
│  - Earn: 60-90% │   │ (on-chain)   │
│  - LP:   0-30%  │   │ - NORMAL     │
│  - Buffer: 10%  │   │ - VOLATILE   │
└─────────────────┘   │ - DRAWDOWN   │
                      └──────────────┘
```

## 🧩 Core Contracts

### 1. **MetaVault.sol**
- ERC4626-compliant vault
- Issues MYV (MetaYield Vault) shares
- **No strategy logic** - pure deposit/withdraw
- 10% performance fee (auto-compounded)
- Minimum deposit: 1 USDT

### 2. **EngineCore.sol**
- **Permissionless orchestrator**
- `executeCycle()` callable by ANYONE
- 1-hour cooldown between cycles
- Cycle logic:
  1. Check volatility (on-chain)
  2. Rebalance if needed
  3. Deploy pending capital
  4. Record harvest + fees

### 3. **StrategyRouter.sol**
- Capital allocation based on market mode:
  - **NORMAL**: 60% Earn, 30% LP, 10% Buffer
  - **VOLATILE**: 80% Earn, 10% LP, 10% Buffer (reduce LP risk)
  - **DRAWDOWN**: 90% Earn, 0% LP, 10% Buffer (exit LP entirely)
- Always maintains 10% USDT buffer for instant withdrawals

### 4. **VolatilityLib.sol**
- On-chain volatility detection
- Uses USDF/USDT PancakeSwap pair spot price
- Thresholds:
  - `< 3% deviation` → NORMAL mode
  - `3-5% deviation` → VOLATILE mode
  - `> 5% deviation` → DRAWDOWN mode
- Computes risk score (0-100)

### 5. **VaultMath.sol**
- Pure calculation helpers
- Allocation splits
- APY computation
- Performance fee shares

## 🔄 Autonomous Cycle Flow

```
┌──────────────────────────────────────────┐
│ 1. Anyone calls executeCycle()           │
│    (enforces 1hr cooldown)               │
└──────────────┬───────────────────────────┘
               │
               ▼
┌──────────────────────────────────────────┐
│ 2. Query USDF/USDT spot price            │
│    Calculate price deviation             │
│    Determine market mode                 │
└──────────────┬───────────────────────────┘
               │
               ▼
┌──────────────────────────────────────────┐
│ 3. Rebalance if:                         │
│    - Market mode changed, OR             │
│    - Drift > 2% from target allocation   │
└──────────────┬───────────────────────────┘
               │
               ▼
┌──────────────────────────────────────────┐
│ 4. Deploy pending capital from vault     │
│    (split between Earn/LP per mode)      │
└──────────────┬───────────────────────────┘
               │
               ▼
┌──────────────────────────────────────────┐
│ 5. Record harvest in vault               │
│    Mint performance fee shares           │
│    Update APY metrics                    │
└──────────────────────────────────────────┘
```

## 🎯 Key Features

### ✅ **No Admin Keys**
- Zero `onlyOwner` modifiers
- No privileged roles
- Fully immutable (no proxy)

### ✅ **Permissionless Execution**
- Anyone can call `executeCycle()`
- State-based cooldown (1 hour)
- Deterministic: outcome depends only on on-chain state

### ✅ **On-Chain Volatility Detection**
- No oracles required
- Uses PancakeSwap V2 spot price
- Real-time market mode switching

### ✅ **Dynamic Risk Management**
- NORMAL: balanced Earn/LP (max yield)
- VOLATILE: reduce LP exposure (preserve capital)
- DRAWDOWN: exit LP entirely (safety mode)

## 📊 Allocation Strategy

| Market Mode | Earn | LP | Buffer | Risk Level |
|-------------|------|----|----|------------|
| **NORMAL** | 60% | 30% | 10% | Low (0-30) |
| **VOLATILE** | 80% | 10% | 10% | Med (30-50) |
| **DRAWDOWN** | 90% | 0% | 10% | High (50-100) |

## 🔐 Security

- **ReentrancyGuard** on all state-changing functions
- **SafeERC20** for token transfers
- **No upgradeable proxy** - code is final
- **No pause mechanism** - always accessible
- **Cooldown protection** - prevents spam/griefing

## 🧪 Testing

```bash
# Start BSC fork
npx hardhat node --fork https://rpc.ankr.com/bsc/YOUR_KEY

# Run tests
npm test
```

## 📝 Deployment Order

1. Deploy adapters (Earn, LP, Farm)
2. Deploy StrategyRouter (pass adapter addresses)
3. Deploy MetaVault (pass EngineCore, StrategyRouter)
4. Deploy EngineCore (pass MetaVault, StrategyRouter)

## 🌟 Hackathon Highlights

- ✨ **Autonomous**: No human intervention required
- ✨ **Permissionless**: Anyone can execute cycles
- ✨ **On-chain**: All decisions based on blockchain state
- ✨ **Modular**: Clean separation of concerns
- ✨ **Immutable**: No admin keys, no upgrades
- ✨ **Educational**: Clear, documented, hackathon-ready

---

**MetaYield: A self-driving yield engine for BSC** 🚀
