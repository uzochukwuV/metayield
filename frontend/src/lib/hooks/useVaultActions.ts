import { useWriteContract, useWaitForTransactionReceipt, useAccount } from 'wagmi';
import { parseUnits } from 'viem';
import { CONTRACTS, VAULT_ABI, ERC20_ABI } from '../contracts';

/**
 * Hook for depositing USDT into the vault
 */
export function useDeposit() {
  const { address } = useAccount();
  const { writeContract, data: hash, isPending, error } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
  });

  const deposit = async (amountUSDT: string) => {
    if (!address) throw new Error('Wallet not connected');

    const assets = parseUnits(amountUSDT, 18); // USDT has 18 decimals on BSC

    return writeContract({
      address: CONTRACTS.VAULT,
      abi: VAULT_ABI,
      functionName: 'deposit',
      args: [assets, address],
    });
  };

  return {
    deposit,
    hash,
    isPending: isPending || isConfirming,
    isSuccess,
    error,
  };
}

/**
 * Hook for withdrawing from the vault (by assets amount)
 */
export function useWithdraw() {
  const { address } = useAccount();
  const { writeContract, data: hash, isPending, error } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
  });

  const withdraw = async (amountUSDT: string) => {
    if (!address) throw new Error('Wallet not connected');

    const assets = parseUnits(amountUSDT, 18);

    return writeContract({
      address: CONTRACTS.VAULT,
      abi: VAULT_ABI,
      functionName: 'withdraw',
      args: [assets, address, address],
    });
  };

  return {
    withdraw,
    hash,
    isPending: isPending || isConfirming,
    isSuccess,
    error,
  };
}

/**
 * Hook for redeeming shares (withdraw by shares amount)
 */
export function useRedeem() {
  const { address } = useAccount();
  const { writeContract, data: hash, isPending, error } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
  });

  const redeem = async (sharesAmount: string) => {
    if (!address) throw new Error('Wallet not connected');

    const shares = parseUnits(sharesAmount, 18);

    return writeContract({
      address: CONTRACTS.VAULT,
      abi: VAULT_ABI,
      functionName: 'redeem',
      args: [shares, address, address],
    });
  };

  return {
    redeem,
    hash,
    isPending: isPending || isConfirming,
    isSuccess,
    error,
  };
}

/**
 * Hook for approving USDT spending by the vault
 */
export function useApproveUSDT() {
  const { writeContract, data: hash, isPending, error } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
  });

  const approve = async (amount?: string) => {
    // Default to max approval if no amount specified
    const approvalAmount = amount
      ? parseUnits(amount, 18)
      : BigInt('0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff');

    return writeContract({
      address: CONTRACTS.USDT,
      abi: ERC20_ABI,
      functionName: 'approve',
      args: [CONTRACTS.VAULT, approvalAmount],
    });
  };

  return {
    approve,
    hash,
    isPending: isPending || isConfirming,
    isSuccess,
    error,
  };
}

/**
 * Hook for permissionless harvest (compound CAKE rewards)
 */
export function useHarvest() {
  const { writeContract, data: hash, isPending, error } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
  });

  const harvest = async () => {
    return writeContract({
      address: CONTRACTS.ENGINE,
      abi: [
        {
          name: 'harvest',
          type: 'function',
          stateMutability: 'nonpayable',
          inputs: [],
          outputs: [{ type: 'bool' }],
        },
      ],
      functionName: 'harvest',
    });
  };

  return {
    harvest,
    hash,
    isPending: isPending || isConfirming,
    isSuccess,
    error,
  };
}

/**
 * Hook for permissionless rebalance
 */
export function useRebalance() {
  const { writeContract, data: hash, isPending, error } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
  });

  const rebalance = async () => {
    return writeContract({
      address: CONTRACTS.ENGINE,
      abi: [
        {
          name: 'checkAndRebalance',
          type: 'function',
          stateMutability: 'nonpayable',
          inputs: [],
          outputs: [{ type: 'bool' }],
        },
      ],
      functionName: 'checkAndRebalance',
    });
  };

  return {
    rebalance,
    hash,
    isPending: isPending || isConfirming,
    isSuccess,
    error,
  };
}
