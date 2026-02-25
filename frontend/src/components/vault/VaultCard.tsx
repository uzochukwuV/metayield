import React, { useState, useEffect } from 'react';
import { ArrowDown, ArrowUp, Info, Wallet, Loader2, CheckCircle, AlertCircle } from 'lucide-react';
import { useAccount, useConnect } from 'wagmi';
import { injected } from 'wagmi/connectors';
import { parseUnits, formatUnits } from 'viem';
import { formatCurrency } from '../../lib/utils';
import { useVaultData, useDepositPreview, useWithdrawPreview } from '../../lib/hooks/useVaultData';
import { useDeposit, useWithdraw, useApproveUSDT } from '../../lib/hooks/useVaultActions';

export function VaultCard() {
  const { isConnected } = useAccount();
  const { connect } = useConnect();
  const [mode, setMode] = useState<'deposit' | 'withdraw'>('deposit');
  const [amount, setAmount] = useState('');

  // Fetch vault data
  const vaultData = useVaultData();

  // Preview calculations
  const parsedAmount = amount && !isNaN(Number(amount)) ? parseUnits(amount, 18) : 0n;
  const depositPreview = useDepositPreview(parsedAmount);
  const withdrawPreview = useWithdrawPreview(parsedAmount);

  // Transaction hooks
  const { deposit, isPending: isDepositing, isSuccess: depositSuccess, error: depositError } = useDeposit();
  const { withdraw, isPending: isWithdrawing, isSuccess: withdrawSuccess, error: withdrawError } = useWithdraw();
  const { approve, isPending: isApproving, isSuccess: approveSuccess } = useApproveUSDT();

  const isPending = isDepositing || isWithdrawing || isApproving;
  const needsApproval = mode === 'deposit' && Number(amount) > vaultData.user.usdtAllowance;

  // Reset amount on success
  useEffect(() => {
    if (depositSuccess || withdrawSuccess) {
      setAmount('');
      vaultData.refetch();
    }
  }, [depositSuccess, withdrawSuccess]);

  const handleMaxClick = () => {
    if (mode === 'deposit') {
      setAmount(vaultData.user.usdtBalance.toString());
    } else {
      // For withdraw, set to max MYV balance worth of USDT
      const maxAssets = vaultData.user.myvBalance * vaultData.sharePrice;
      setAmount(maxAssets.toString());
    }
  };

  const handleSubmit = async () => {
    try {
      if (!amount || Number(amount) <= 0) return;

      if (mode === 'deposit') {
        if (needsApproval) {
          await approve();
        } else {
          await deposit(amount);
        }
      } else {
        await withdraw(amount);
      }
    } catch (err) {
      console.error('Transaction failed:', err);
    }
  };

  const sharesPreview = mode === 'deposit'
    ? Number(formatUnits(depositPreview.shares, 18))
    : Number(formatUnits(withdrawPreview.assets, 18)) / vaultData.sharePrice;

  return (
    <div className="glass-panel p-6">
      <div className="flex p-1 bg-white/5 rounded-xl mb-6">
        <button
          onClick={() => setMode('deposit')}
          className={`flex-1 py-2 text-sm font-semibold rounded-lg transition-all ${
            mode === 'deposit' ? 'bg-brand-primary text-black' : 'text-white/60 hover:text-white'
          }`}
        >
          Deposit
        </button>
        <button
          onClick={() => setMode('withdraw')}
          className={`flex-1 py-2 text-sm font-semibold rounded-lg transition-all ${
            mode === 'withdraw' ? 'bg-brand-primary text-black' : 'text-white/60 hover:text-white'
          }`}
        >
          Withdraw
        </button>
      </div>

      <div className="space-y-4">
        <div>
          <div className="flex justify-between text-sm mb-2">
            <span className="text-white/60">Amount</span>
            <span className="text-white/40">
              Balance: {isConnected
                ? `${(mode === 'deposit' ? vaultData.user.usdtBalance : vaultData.user.myvBalance * vaultData.sharePrice).toFixed(2)} ${mode === 'deposit' ? 'USDT' : 'USDT'}`
                : '0.00 USDT'}
            </span>
          </div>
          <div className="relative">
            <input
              type="number"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              placeholder="0.00"
              disabled={!isConnected || isPending}
              className="w-full bg-white/5 border border-white/10 rounded-xl px-4 py-4 text-xl font-bold focus:outline-none focus:border-brand-primary transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
            />
            <div className="absolute right-4 top-1/2 -translate-y-1/2 flex items-center gap-2">
              <span className="font-bold text-white/60">USDT</span>
              {isConnected && !isPending && (
                <button
                  onClick={handleMaxClick}
                  className="text-xs font-bold text-brand-primary hover:text-brand-primary/80"
                >
                  MAX
                </button>
              )}
            </div>
          </div>
        </div>

        <div className="p-4 bg-white/5 rounded-xl space-y-3">
          <div className="flex justify-between text-sm">
            <span className="text-white/60">You will {mode === 'deposit' ? 'receive' : 'burn'}</span>
            <span className="font-medium">
              {sharesPreview.toFixed(4)} MYV
            </span>
          </div>
          <div className="flex justify-between text-sm">
            <span className="text-white/60">Exchange Rate</span>
            <span className="font-medium">1 MYV = {vaultData.sharePrice.toFixed(4)} USDT</span>
          </div>
          <div className="flex justify-between text-sm">
            <span className="text-white/60">Performance Fee</span>
            <span className="font-medium">{vaultData.performanceFeeBps.toFixed(1)}%</span>
          </div>
        </div>

        {/* Transaction status messages */}
        {depositSuccess && (
          <div className="flex items-center gap-2 p-3 bg-emerald-500/10 border border-emerald-500/20 rounded-lg text-emerald-400 text-sm">
            <CheckCircle size={16} />
            <span>Deposit successful!</span>
          </div>
        )}
        {withdrawSuccess && (
          <div className="flex items-center gap-2 p-3 bg-emerald-500/10 border border-emerald-500/20 rounded-lg text-emerald-400 text-sm">
            <CheckCircle size={16} />
            <span>Withdrawal successful!</span>
          </div>
        )}
        {(depositError || withdrawError) && (
          <div className="flex items-center gap-2 p-3 bg-red-500/10 border border-red-500/20 rounded-lg text-red-400 text-sm">
            <AlertCircle size={16} />
            <span>Transaction failed. Please try again.</span>
          </div>
        )}

        {isConnected ? (
          <button
            onClick={handleSubmit}
            disabled={isPending || !amount || Number(amount) <= 0 || vaultData.isLoading}
            className="btn-primary w-full py-4 text-lg flex items-center justify-center gap-2 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {isPending && <Loader2 size={20} className="animate-spin" />}
            {isPending
              ? isApproving
                ? 'Approving USDT...'
                : mode === 'deposit'
                ? 'Depositing...'
                : 'Withdrawing...'
              : needsApproval
              ? 'Approve USDT'
              : mode === 'deposit'
              ? 'Deposit USDT'
              : 'Withdraw USDT'}
          </button>
        ) : (
          <button
            onClick={() => connect({ connector: injected() })}
            className="btn-primary w-full py-4 text-lg flex items-center justify-center gap-2"
          >
            <Wallet size={20} />
            Connect Wallet to {mode === 'deposit' ? 'Deposit' : 'Withdraw'}
          </button>
        )}

        <div className="flex items-center gap-2 text-xs text-white/40 justify-center">
          <Info size={14} />
          <span>Non-custodial. Funds are managed by immutable smart contracts.</span>
        </div>
      </div>
    </div>
  );
}
