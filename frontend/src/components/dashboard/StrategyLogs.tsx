import React from 'react';
import { CheckCircle2, RefreshCw, AlertCircle, ArrowRight } from 'lucide-react';
import { formatCurrency } from '../../lib/utils';

const logs = [
  {
    id: 1,
    type: 'rebalance',
    status: 'success',
    time: '2 hours ago',
    message: 'Rebalanced allocations: Earn +2.5%, LP -2.5%',
    details: 'Triggered by 0.8% drift from target NORMAL mode.'
  },
  {
    id: 2,
    type: 'harvest',
    status: 'success',
    time: '5 hours ago',
    message: 'Harvested 1,240.50 USDT from AsterDEX Earn',
    details: 'Yield auto-compounded into MetaVault.'
  },
  {
    id: 3,
    type: 'mode_change',
    status: 'warning',
    time: '1 day ago',
    message: 'Market Mode shifted: VOLATILE → NORMAL',
    details: 'Volatility dropped below 3% threshold.'
  },
  {
    id: 4,
    type: 'rebalance',
    status: 'success',
    time: '1 day ago',
    message: 'De-risked LP positions',
    details: 'Shifted 20% capital to Earn buffer during volatility spike.'
  }
];

export function StrategyLogs() {
  return (
    <div className="glass-panel p-6">
      <div className="flex items-center justify-between mb-6">
        <h3 className="text-lg font-bold">Strategy Logs</h3>
        <button className="text-xs text-brand-primary hover:underline flex items-center gap-1">
          View Explorer <ArrowRight size={12} />
        </button>
      </div>

      <div className="space-y-4">
        {logs.map((log) => (
          <div key={log.id} className="flex gap-4 p-3 rounded-xl hover:bg-white/5 transition-colors group">
            <div className="mt-1">
              {log.status === 'success' ? (
                <CheckCircle2 size={16} className="text-emerald-400" />
              ) : log.status === 'warning' ? (
                <AlertCircle size={16} className="text-orange-400" />
              ) : (
                <RefreshCw size={16} className="text-blue-400" />
              )}
            </div>
            <div className="flex-1">
              <div className="flex justify-between items-start mb-1">
                <p className="text-sm font-medium text-white group-hover:text-brand-primary transition-colors">
                  {log.message}
                </p>
                <span className="text-[10px] text-white/30 whitespace-nowrap ml-2">{log.time}</span>
              </div>
              <p className="text-xs text-white/50 leading-relaxed">
                {log.details}
              </p>
            </div>
          </div>
        ))}
      </div>
      
      <button className="w-full mt-6 py-2 text-xs font-medium text-white/40 hover:text-white transition-colors border border-white/5 rounded-lg hover:bg-white/5">
        Load More Activity
      </button>
    </div>
  );
}
