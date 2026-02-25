import React, { useState } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { WagmiProvider, createConfig, http } from 'wagmi';
import { bsc } from 'wagmi/chains';
import { Header } from './components/layout/Header';
import { StatsGrid } from './components/dashboard/StatsGrid';
import { AllocationChart } from './components/dashboard/AllocationChart';
import { YieldChart } from './components/dashboard/YieldChart';
import { StrategyLogs } from './components/dashboard/StrategyLogs';
import { VaultCard } from './components/vault/VaultCard';
import { CycleStatus } from './components/vault/CycleStatus';
import { LandingHero } from './components/landing/LandingHero';
import { motion, AnimatePresence } from 'motion/react';
import { useVaultData } from './lib/hooks/useVaultData';
import { MARKET_MODE_LABELS } from './lib/contracts';

const queryClient = new QueryClient();

// Use custom RPC from environment or fallback to public RPC
const BSC_RPC = 'https://rpc.ankr.com/bsc/34e09c0b23e338cc418de4198834f827a1ddfc21af2f3bcafd94a5370ff59dea';

const config = createConfig({
  chains: [bsc],
  transports: {
    [bsc.id]: http(BSC_RPC),
  },
});

function DashboardContent() {
  const vaultData = useVaultData();

  return (
    <>
      <Header />
      <main className="container mx-auto px-4 py-8 space-y-8">
        <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
          <div>
            <h1 className="text-3xl font-bold font-display">MetaYield Dashboard</h1>
            <p className="text-white/60">Manage your autonomous yield engine on BNB Chain.</p>
          </div>
          <div className="flex items-center gap-3">
            <div className="flex items-center gap-2 px-3 py-1.5 bg-white/5 rounded-lg border border-white/10">
              <div className="w-2 h-2 rounded-full bg-emerald-400" />
              <span className="text-xs font-medium">BNB Smart Chain</span>
            </div>
          </div>
        </div>

        <StatsGrid />

        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
          <div className="lg:col-span-2 space-y-8">
            <YieldChart />
            <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
              <AllocationChart />
              <CycleStatus />
            </div>
            <StrategyLogs />
          </div>
          <div className="space-y-8">
            <VaultCard />

            {/* Strategy Insights with Real Data */}
            <div className="glass-panel p-6">
              <h3 className="text-lg font-bold mb-4">Strategy Insights</h3>
              <div className="space-y-4">
                <div className="flex justify-between text-sm">
                  <span className="text-white/60">Current Mode</span>
                  <span className="font-medium text-emerald-400">
                    {MARKET_MODE_LABELS[vaultData.currentMode]}
                  </span>
                </div>
                <div className="flex justify-between text-sm">
                  <span className="text-white/60">Earn Allocation</span>
                  <span className="font-medium text-white">
                    {vaultData.allocations.earn.toFixed(1)}%
                  </span>
                </div>
                <div className="flex justify-between text-sm">
                  <span className="text-white/60">Hedge Allocation</span>
                  <span className="font-medium text-brand-primary">
                    {vaultData.allocations.hedge.toFixed(1)}%
                  </span>
                </div>
                <div className="flex justify-between text-sm">
                  <span className="text-white/60">LP Allocation</span>
                  <span className="font-medium text-white">
                    {vaultData.allocations.lp.toFixed(1)}%
                  </span>
                </div>
                <div className="flex justify-between text-sm">
                  <span className="text-white/60">Buffer</span>
                  <span className="font-medium text-white">
                    {vaultData.allocations.buffer.toFixed(1)}%
                  </span>
                </div>
                <div className="flex justify-between text-sm">
                  <span className="text-white/60">Share Price</span>
                  <span className="font-medium text-white/60">
                    ${vaultData.sharePrice.toFixed(4)}
                  </span>
                </div>
              </div>
              <div className="mt-6 pt-6 border-t border-white/5">
                <p className="text-xs text-white/40 leading-relaxed">
                  The strategy automatically rebalances based on market volatility.
                  Hedge allocation increases from 20% (NORMAL) → 40% (VOLATILE) → 50% (DRAWDOWN)
                  to protect against USD weakness.
                </p>
              </div>
            </div>
          </div>
        </div>
      </main>

      <footer className="border-t border-white/5 py-12 mt-12 bg-[#0B0E11]">
        <div className="container mx-auto px-4 flex flex-col md:flex-row justify-between items-center gap-8">
          <div className="flex items-center gap-2">
            <div className="w-6 h-6 bg-brand-primary rounded flex items-center justify-center">
              <span className="text-black font-bold text-sm">M</span>
            </div>
            <span className="font-display font-bold text-lg">MetaYield Vault</span>
          </div>
          <div className="flex gap-8 text-sm text-white/40">
            <a href="#" className="hover:text-white transition-colors">Documentation</a>
            <a href="#" className="hover:text-white transition-colors">GitHub</a>
            <a href="#" className="hover:text-white transition-colors">Audit</a>
            <a href="#" className="hover:text-white transition-colors">Terms</a>
          </div>
          <p className="text-sm text-white/20">© 2024 MetaYield Protocol. Built for BNB Chain.</p>
        </div>
      </footer>
    </>
  );
}

export default function App() {
  const [showDashboard, setShowDashboard] = useState(false);

  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <div className="min-h-screen bg-[#0B0E11]">
          <AnimatePresence mode="wait">
            {!showDashboard ? (
              <motion.div
                key="landing"
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                exit={{ opacity: 0 }}
              >
                <LandingHero onEnter={() => setShowDashboard(true)} />
              </motion.div>
            ) : (
              <motion.div
                key="dashboard"
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                className="flex flex-col"
              >
                <DashboardContent />
              </motion.div>
            )}
          </AnimatePresence>
        </div>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
