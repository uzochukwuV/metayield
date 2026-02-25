# MetaYield Vault Frontend

React + Vite + TypeScript frontend for the MetaYield autonomous yield engine on BNB Chain.

## Features

- **Deposit/Withdraw Interface**: ERC4626-compliant vault interactions with USDT
- **Real-time Stats**: TVL, APY, Market Mode, Risk Score
- **Live Allocations**: View current Earn/Hedge/LP/Buffer allocation ratios
- **Strategy Insights**: Market mode and hedge protection status
- **Wallet Integration**: Wagmi v3 with MetaMask/WalletConnect support
- **BSC Mainnet**: Optimized for BNB Smart Chain

## Tech Stack

- **React 19** with TypeScript
- **Vite** for fast development
- **Wagmi v3** + Viem for Web3 integration
- **TanStack Query** for data fetching
- **Tailwind CSS v4** for styling
- **Motion** (Framer Motion fork) for animations

## Setup

### 1. Install Dependencies

```bash
cd frontend
npm install
```

### 2. Configure Contract Addresses

Before running the frontend, you need to update the contract addresses in `src/lib/contracts.ts`:

```typescript
export const CONTRACTS = {
  // Update these with your deployed contract addresses
  VAULT: '0xYourVaultAddress',
  ENGINE: '0xYourEngineAddress',
  ROUTER: '0xYourRouterAddress',
  MYV: '0xYourVaultAddress', // Same as VAULT (ERC4626 shares)

  // These are BSC mainnet addresses (already correct)
  USDT: '0x55d398326f99059fF775485246999027B3197955',
  ASUSDF: '0x917AF46B3C3c6e1Bb7286B9F59637Fb7C65851Fb',
  ASBNB: '0x77734e70b6E88b4d82fE632a168EDf6e700912b6',
} as const;
```

### 3. Run Development Server

```bash
npm run dev
```

The app will be available at `http://localhost:3000`

### 4. Build for Production

```bash
npm run build
```

Built files will be in the `dist/` directory.

## Contract Integration

### Hooks Available

#### Reading Data

- **`useVaultData()`** - Fetches all vault and strategy metrics in a single multicall
  - Returns: TVL, share price, APY, mode, allocations, user balances
  - Auto-refetches every 12 seconds (1 BSC block)

- **`useDepositPreview(assets)`** - Calculates shares for a given USDT amount
- **`useWithdrawPreview(shares)`** - Calculates USDT for a given shares amount

#### Transactions

- **`useDeposit()`** - Deposit USDT → receive MYV shares
- **`useWithdraw()`** - Withdraw by assets amount
- **`useRedeem()`** - Withdraw by shares amount
- **`useApproveUSDT()`** - Approve USDT spending
- **`useHarvest()`** - Permissionless harvest of CAKE rewards
- **`useRebalance()`** - Permissionless rebalance trigger

### Example Usage

```typescript
import { useVaultData, useDeposit } from './lib/hooks';

function Component() {
  const vaultData = useVaultData();
  const { deposit, isPending } = useDeposit();

  const handleDeposit = async () => {
    await deposit('100'); // Deposit 100 USDT
  };

  return (
    <div>
      <p>TVL: ${vaultData.tvl.toFixed(2)}</p>
      <p>APY: {vaultData.apy.toFixed(2)}%</p>
      <button onClick={handleDeposit} disabled={isPending}>
        {isPending ? 'Depositing...' : 'Deposit'}
      </button>
    </div>
  );
}
```

## Architecture

```
frontend/
├── src/
│   ├── components/
│   │   ├── dashboard/        # Stats, charts, logs
│   │   ├── layout/           # Header, navigation
│   │   ├── landing/          # Landing page hero
│   │   └── vault/            # Deposit/withdraw card
│   ├── lib/
│   │   ├── hooks/            # Contract interaction hooks
│   │   │   ├── useVaultData.ts
│   │   │   └── useVaultActions.ts
│   │   ├── contracts.ts      # ABIs and addresses
│   │   └── utils.ts          # Helper functions
│   ├── App.tsx               # Main app component
│   └── main.tsx              # Entry point
├── package.json
└── vite.config.ts
```

## Key Features

### 1. Deposit Flow

1. User enters USDT amount
2. If no approval → triggers `approve()` transaction
3. After approval → triggers `deposit()` transaction
4. Shares are minted and displayed

### 2. Withdraw Flow

1. User enters USDT amount to withdraw
2. Calculates shares to burn using `convertToShares()`
3. Triggers `withdraw()` transaction
4. USDT is returned to user

### 3. Real-time Updates

- All data refetches every 12 seconds (1 BSC block)
- Transaction status shows loading/success/error states
- Balance updates automatically after transactions

### 4. Market Modes

- **NORMAL**: 60% Earn, 20% Hedge, 10% LP, 10% Buffer
- **VOLATILE**: 40% Earn, 40% Hedge, 10% LP, 10% Buffer
- **DRAWDOWN**: 20% Earn, 50% Hedge, 0% LP, 30% Buffer

Colors change based on mode for visual clarity.

## Network Configuration

The app is configured for **BSC Mainnet (chainId: 56)** by default.

To switch networks, update the Wagmi config in `App.tsx`:

```typescript
const config = createConfig({
  chains: [bsc], // or bscTestnet for testing
  transports: {
    [bsc.id]: http(),
  },
});
```

## Troubleshooting

### "Cannot read properties of undefined"

- Make sure contract addresses in `contracts.ts` are correct
- Verify you're connected to BSC Mainnet (chainId 56)
- Check that contracts are deployed at the specified addresses

### Transactions Failing

- Ensure you have enough BNB for gas fees
- Check USDT balance is sufficient for deposits
- Verify USDT approval was successful before depositing

### Wallet Not Connecting

- Make sure MetaMask is installed
- Add BSC Mainnet to your wallet
- Grant connection permissions when prompted

## Production Deployment

### Update Contract Addresses

Before deploying to production, update all contract addresses in `src/lib/contracts.ts` with your actual deployed addresses.

### Build and Deploy

```bash
npm run build
```

Deploy the `dist/` folder to your hosting service:
- Vercel
- Netlify
- AWS S3 + CloudFront
- IPFS (for decentralized hosting)

## License

MIT
