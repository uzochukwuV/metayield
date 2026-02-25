// Contract addresses on BSC Mainnet
export const CONTRACTS = {
  // Core protocol contracts (replace with actual deployed addresses)
  VAULT: '0x0000000000000000000000000000000000000000', // MetaYield ERC4626 vault
  ENGINE: '0x0000000000000000000000000000000000000000', // AutonomousEngine
  ROUTER: '0x0000000000000000000000000000000000000000', // StrategyRouter

  // Tokens
  USDT: '0x55d398326f99059fF775485246999027B3197955',
  MYV: '0x0000000000000000000000000000000000000000', // MYV token (vault shares)

  // AsterDEX
  ASUSDF: '0x917AF46B3C3c6e1Bb7286B9F59637Fb7C65851Fb',
  ASBNB: '0x77734e70b6E88b4d82fE632a168EDf6e700912b6',
} as const;

// ERC20 ABI (minimal for USDT/MYV token interactions)
export const ERC20_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address,address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
  'function decimals() view returns (uint8)',
  'function symbol() view returns (string)',
] as const;

// ERC4626 Vault ABI
export const VAULT_ABI = [
  // ERC4626 view functions
  'function totalAssets() view returns (uint256)',
  'function convertToShares(uint256 assets) view returns (uint256)',
  'function convertToAssets(uint256 shares) view returns (uint256)',
  'function maxDeposit(address) view returns (uint256)',
  'function maxWithdraw(address) view returns (uint256)',

  // ERC4626 state-changing functions
  'function deposit(uint256 assets, address receiver) returns (uint256 shares)',
  'function withdraw(uint256 assets, address receiver, address owner) returns (uint256 shares)',
  'function redeem(uint256 shares, address receiver, address owner) returns (uint256 assets)',

  // MetaYield-specific view functions
  'function performanceFeeBps() view returns (uint256)',
  'function highWaterMark() view returns (uint256)',
  'function totalSupply() view returns (uint256)',

  // Events
  'event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)',
  'event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)',
] as const;

// AutonomousEngine ABI
export const ENGINE_ABI = [
  'function currentMode() view returns (uint8)',
  'function riskScore() view returns (uint256)',
  'function lastModeChange() view returns (uint256)',
  'function volatilityThresholds(uint256) view returns (uint256)',

  // Permissionless functions
  'function checkAndRebalance() returns (bool)',
  'function harvest() returns (bool)',

  // Events
  'event ModeChanged(uint8 indexed oldMode, uint8 indexed newMode, uint256 riskScore)',
  'event Harvested(uint256 cakeAmount, uint256 usdtReceived)',
] as const;

// StrategyRouter ABI
export const ROUTER_ABI = [
  'function earnAllocationBps() view returns (uint256)',
  'function hedgeAllocationBps() view returns (uint256)',
  'function lpAllocationBps() view returns (uint256)',
  'function bufferAllocationBps() view returns (uint256)',

  'function totalManagedAssets() view returns (uint256)',

  'event Rebalanced(uint256 earnBps, uint256 hedgeBps, uint256 lpBps)',
] as const;

// Market modes enum (matches VolatilityLib.MarketMode)
export enum MarketMode {
  NORMAL = 0,
  VOLATILE = 1,
  DRAWDOWN = 2,
}

export const MARKET_MODE_LABELS: Record<MarketMode, string> = {
  [MarketMode.NORMAL]: 'NORMAL',
  [MarketMode.VOLATILE]: 'VOLATILE',
  [MarketMode.DRAWDOWN]: 'DRAWDOWN',
};

export const MARKET_MODE_STATUS: Record<MarketMode, string> = {
  [MarketMode.NORMAL]: 'Stable',
  [MarketMode.VOLATILE]: 'High Volatility',
  [MarketMode.DRAWDOWN]: 'Market Stress',
};

export const MARKET_MODE_COLORS: Record<MarketMode, string> = {
  [MarketMode.NORMAL]: 'text-emerald-400',
  [MarketMode.VOLATILE]: 'text-orange-400',
  [MarketMode.DRAWDOWN]: 'text-red-400',
};
