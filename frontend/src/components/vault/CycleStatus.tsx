import React from 'react';
import { RefreshCw, Clock, AlertTriangle } from 'lucide-react';
import { motion } from 'motion/react';

export function CycleStatus() {
  return (
    <div className="glass-panel p-6">
      <div className="flex items-center justify-between mb-6">
        <h3 className="text-lg font-bold">Autonomous Engine</h3>
        <span className="flex items-center gap-1.5 text-xs font-medium text-emerald-400 bg-emerald-400/10 px-2 py-1 rounded-full">
          <div className="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse" />
          Active
        </span>
      </div>

      <div className="space-y-6">
        <div className="flex items-center gap-4">
          <div className="w-12 h-12 rounded-full bg-white/5 flex items-center justify-center text-brand-primary">
            <Clock size={24} />
          </div>
          <div>
            <p className="text-sm text-white/60">Next Cycle Available In</p>
            <p className="text-xl font-bold font-mono">00:42:15</p>
          </div>
        </div>

        <div className="p-4 bg-orange-400/5 border border-orange-400/10 rounded-xl flex gap-3">
          <AlertTriangle className="text-orange-400 shrink-0" size={20} />
          <p className="text-xs text-orange-400/80 leading-relaxed">
            The engine is currently in <span className="font-bold">NORMAL</span> mode. 
            Volatility is low (1.2%). Rebalancing will occur if deviation exceeds 2%.
          </p>
        </div>

        <button disabled className="btn-secondary w-full flex items-center justify-center gap-2 opacity-50 cursor-not-allowed">
          <RefreshCw size={18} />
          <span>Execute Cycle</span>
        </button>
        
        <p className="text-[10px] text-center text-white/30">
          Anyone can execute the cycle once the 1-hour cooldown expires. 
          Gas fees are paid by the executor.
        </p>
      </div>
    </div>
  );
}
