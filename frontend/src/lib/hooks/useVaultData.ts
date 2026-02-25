import { useReadContracts, useAccount } from 'wagmi';
import { formatUnits } from 'viem';
import { CONTRACTS, VAULT_ABI, ENGINE_ABI, ROUTER_ABI, ERC20_ABI, MarketMode } from '../contracts';

/**
 * Hook to read all vault and strategy data in a single multicall
 */
export function useVaultData() {
  const { address } = useAccount();

  const { data, isLoading, error, refetch } = useReadContracts({
    contracts: [
      // Vault metrics
      { address: CONTRACTS.VAULT, abi: VAULT_ABI, functionName: 'totalAssets' },
      { address: CONTRACTS.VAULT, abi: VAULT_ABI, functionName: 'totalSupply' },
      { address: CONTRACTS.VAULT, abi: VAULT_ABI, functionName: 'performanceFeeBps' },
      { address: CONTRACTS.VAULT, abi: VAULT_ABI, functionName: 'highWaterMark' },

      // Engine metrics
      { address: CONTRACTS.ENGINE, abi: ENGINE_ABI, functionName: 'currentMode' },
      { address: CONTRACTS.ENGINE, abi: ENGINE_ABI, functionName: 'riskScore' },

      // Router allocations
      { address: CONTRACTS.ROUTER, abi: ROUTER_ABI, functionName: 'earnAllocationBps' },
      { address: CONTRACTS.ROUTER, abi: ROUTER_ABI, functionName: 'hedgeAllocationBps' },
      { address: CONTRACTS.ROUTER, abi: ROUTER_ABI, functionName: 'lpAllocationBps' },
      { address: CONTRACTS.ROUTER, abi: ROUTER_ABI, functionName: 'bufferAllocationBps' },
      { address: CONTRACTS.ROUTER, abi: ROUTER_ABI, functionName: 'totalManagedAssets' },

      // User balances (if connected)
      ...(address
        ? [
            { address: CONTRACTS.USDT, abi: ERC20_ABI, functionName: 'balanceOf', args: [address] },
            { address: CONTRACTS.MYV, abi: ERC20_ABI, functionName: 'balanceOf', args: [address] },
            { address: CONTRACTS.USDT, abi: ERC20_ABI, functionName: 'allowance', args: [address, CONTRACTS.VAULT] },
          ]
        : []),
    ] as const,
    query: {
      refetchInterval: 12_000, // Refetch every 12 seconds (1 BSC block)
    },
  });

  // Parse results
  const [
    totalAssetsResult,
    totalSupplyResult,
    perfFeeBpsResult,
    highWaterMarkResult,
    currentModeResult,
    riskScoreResult,
    earnBpsResult,
    hedgeBpsResult,
    lpBpsResult,
    bufferBpsResult,
    totalManagedResult,
    usdtBalanceResult,
    myvBalanceResult,
    usdtAllowanceResult,
  ] = data || [];

  // Calculate share price (NAV per share)
  const totalAssets = totalAssetsResult?.result
    ? Number(formatUnits(totalAssetsResult.result as bigint, 18))
    : 0;
  const totalSupply = totalSupplyResult?.result
    ? Number(formatUnits(totalSupplyResult.result as bigint, 18))
    : 1;

  const sharePrice = totalSupply > 0 ? totalAssets / totalSupply : 1.0;

  // Parse mode
  const currentMode = (currentModeResult?.result as number) ?? MarketMode.NORMAL;

  // Parse allocations
  const earnBps = (earnBpsResult?.result as bigint) ?? 0n;
  const hedgeBps = (hedgeBpsResult?.result as bigint) ?? 0n;
  const lpBps = (lpBpsResult?.result as bigint) ?? 0n;
  const bufferBps = (bufferBpsResult?.result as bigint) ?? 0n;

  // Calculate APY (simplified - in production, track over time)
  // For now, estimate based on share price > 1.0
  const estimatedAPY = (sharePrice - 1.0) * 100 * 365; // Annualized from current appreciation

  // User balances
  const usdtBalance = usdtBalanceResult?.result
    ? Number(formatUnits(usdtBalanceResult.result as bigint, 18))
    : 0;
  const myvBalance = myvBalanceResult?.result
    ? Number(formatUnits(myvBalanceResult.result as bigint, 18))
    : 0;
  const usdtAllowance = usdtAllowanceResult?.result
    ? Number(formatUnits(usdtAllowanceResult.result as bigint, 18))
    : 0;

  return {
    // Vault metrics
    tvl: totalAssets,
    totalSupply,
    sharePrice,
    performanceFeeBps: Number(perfFeeBpsResult?.result ?? 1000n) / 100, // Convert to percentage
    highWaterMark: Number(formatUnits((highWaterMarkResult?.result as bigint) ?? 0n, 18)),

    // Strategy metrics
    currentMode,
    riskScore: Number(riskScoreResult?.result ?? 0n),
    apy: estimatedAPY,

    // Allocations
    allocations: {
      earn: Number(earnBps) / 100, // Convert BPS to percentage
      hedge: Number(hedgeBps) / 100,
      lp: Number(lpBps) / 100,
      buffer: Number(bufferBps) / 100,
    },

    // Total managed
    totalManaged: Number(formatUnits((totalManagedResult?.result as bigint) ?? 0n, 18)),

    // User balances
    user: {
      usdtBalance,
      myvBalance,
      usdtAllowance,
      hasApproval: usdtAllowance > 0,
    },

    // Query state
    isLoading,
    error,
    refetch,
  };
}

/**
 * Hook to calculate shares for a given USDT amount (deposit preview)
 */
export function useDepositPreview(assets: bigint) {
  const { data, isLoading } = useReadContracts({
    contracts: [
      {
        address: CONTRACTS.VAULT,
        abi: VAULT_ABI,
        functionName: 'convertToShares',
        args: [assets],
      },
    ],
  });

  const shares = data?.[0]?.result ? (data[0].result as bigint) : 0n;

  return {
    shares,
    isLoading,
  };
}

/**
 * Hook to calculate assets for a given shares amount (withdraw preview)
 */
export function useWithdrawPreview(shares: bigint) {
  const { data, isLoading } = useReadContracts({
    contracts: [
      {
        address: CONTRACTS.VAULT,
        abi: VAULT_ABI,
        functionName: 'convertToAssets',
        args: [shares],
      },
    ],
  });

  const assets = data?.[0]?.result ? (data[0].result as bigint) : 0n;

  return {
    assets,
    isLoading,
  };
}
