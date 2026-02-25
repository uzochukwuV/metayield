import React from 'react';
import { motion } from 'motion/react';
import { ArrowRight, Shield, Zap, Layers, Globe } from 'lucide-react';

export function LandingHero({ onEnter }: { onEnter: () => void }) {
  return (
    <div className="min-h-screen flex flex-col items-center justify-center relative overflow-hidden px-4">
      {/* Background Glows */}
      <div className="absolute top-1/4 -left-1/4 w-96 h-96 bg-brand-primary/20 rounded-full blur-[120px]" />
      <div className="absolute bottom-1/4 -right-1/4 w-96 h-96 bg-blue-500/10 rounded-full blur-[120px]" />

      <motion.div
        initial={{ opacity: 0, y: 20 }}
        animate={{ opacity: 1, y: 0 }}
        className="text-center max-w-4xl relative z-10"
      >
        <div className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-white/5 border border-white/10 text-xs font-medium text-brand-primary mb-8">
          <span className="relative flex h-2 w-2">
            <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-brand-primary opacity-75"></span>
            <span className="relative inline-flex rounded-full h-2 w-2 bg-brand-primary"></span>
          </span>
          BNB Chain Yield Strategy Hackathon
        </div>
        
        <h1 className="text-5xl md:text-7xl font-bold mb-6 leading-tight">
          The Self-Driving <br />
          <span className="text-brand-primary">Yield Engine</span>
        </h1>
        
        <p className="text-lg md:text-xl text-white/60 mb-10 max-w-2xl mx-auto leading-relaxed">
          Fully autonomous, non-custodial yield infrastructure on BNB Chain. 
          Smart contracts, not humans, managing your capital for superior risk-adjusted returns.
        </p>

        <div className="flex flex-col sm:flex-row items-center justify-center gap-4">
          <button onClick={onEnter} className="btn-primary px-8 py-4 text-lg flex items-center gap-2 group">
            Launch App
            <ArrowRight size={20} className="group-hover:translate-x-1 transition-transform" />
          </button>
          <button className="btn-secondary px-8 py-4 text-lg">
            Read Documentation
          </button>
        </div>
      </motion.div>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-8 mt-24 max-w-6xl w-full relative z-10">
        {[
          {
            icon: Shield,
            title: '100% Non-Custodial',
            desc: 'Your funds are governed solely by immutable smart contracts. No admin keys, no multisigs.'
          },
          {
            icon: Zap,
            title: 'Autonomous Execution',
            desc: 'Deterministic rebalancing cycles driven by on-chain volatility detection.'
          },
          {
            icon: Layers,
            title: 'Composable Yield',
            desc: 'Stack yield across AsterDEX Earn and PancakeSwap LPs programmatically.'
          }
        ].map((feature, i) => (
          <motion.div
            key={i}
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.4 + i * 0.1 }}
            className="glass-panel p-8 text-left"
          >
            <div className="w-12 h-12 rounded-xl bg-brand-primary/10 flex items-center justify-center text-brand-primary mb-6">
              <feature.icon size={24} />
            </div>
            <h3 className="text-xl font-bold mb-3">{feature.title}</h3>
            <p className="text-white/50 text-sm leading-relaxed">{feature.desc}</p>
          </motion.div>
        ))}
      </div>
    </div>
  );
}
