import React from 'react';
import { TrendingUp, Shield, Zap, Activity } from 'lucide-react';
import { formatCurrency, formatPercent } from '../../lib/utils';
import { motion } from 'motion/react';
import { useVaultData } from '../../lib/hooks/useVaultData';
import { MARKET_MODE_LABELS, MARKET_MODE_STATUS, MARKET_MODE_COLORS } from '../../lib/contracts';

export function StatsGrid() {
  const vaultData = useVaultData();

  // Determine risk status based on score
  const getRiskStatus = (score: number) => {
    if (score < 20) return 'Low Risk';
    if (score < 50) return 'Medium Risk';
    return 'High Risk';
  };

  const getRiskColor = (score: number) => {
    if (score < 20) return 'text-emerald-400';
    if (score < 50) return 'text-orange-400';
    return 'text-red-400';
  };

  const stats = [
    {
      label: 'Total Value Locked',
      value: vaultData.tvl,
      change: vaultData.tvl > 0 ? '+12.5%' : undefined, // TODO: Track historical change
      icon: Shield,
      color: 'text-emerald-400',
      isCurrency: true,
    },
    {
      label: 'Current APY',
      value: vaultData.apy,
      change: vaultData.apy > 0 ? '+2.1%' : undefined, // TODO: Track historical change
      icon: TrendingUp,
      color: 'text-brand-primary',
      isPercent: true,
    },
    {
      label: 'Market Mode',
      value: MARKET_MODE_LABELS[vaultData.currentMode],
      status: MARKET_MODE_STATUS[vaultData.currentMode],
      icon: Activity,
      color: MARKET_MODE_COLORS[vaultData.currentMode],
    },
    {
      label: 'Risk Score',
      value: vaultData.riskScore,
      status: getRiskStatus(vaultData.riskScore),
      icon: Zap,
      color: getRiskColor(vaultData.riskScore),
    },
  ];

  return (
    <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
      {stats.map((stat, index) => (
        <motion.div
          key={stat.label}
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: index * 0.1 }}
          className="glass-panel p-6"
        >
          <div className="flex items-start justify-between mb-4">
            <div className={stat.color}>
              <stat.icon size={24} />
            </div>
            {stat.change && (
              <span className="text-xs font-medium text-emerald-400 bg-emerald-400/10 px-2 py-1 rounded-full">
                {stat.change}
              </span>
            )}
            {stat.status && (
              <span className={stat.color + " text-xs font-medium bg-current/10 px-2 py-1 rounded-full"}>
                {stat.status}
              </span>
            )}
          </div>
          <p className="text-sm text-white/60 mb-1">{stat.label}</p>
          <h3 className="text-2xl font-bold font-display">
            {typeof stat.value === 'number' 
              ? (stat.isCurrency ? formatCurrency(stat.value) : formatPercent(stat.value))
              : stat.value}
          </h3>
        </motion.div>
      ))}
    </div>
  );
}
