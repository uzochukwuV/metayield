import React from 'react';
import { Wallet, Menu, Bell, LogOut } from 'lucide-react';
import { useAccount, useConnect, useDisconnect } from 'wagmi';
import { injected } from 'wagmi/connectors';
import { cn } from '../../lib/utils';

export function Header() {
  const { address, isConnected } = useAccount();
  const { connect } = useConnect();
  const { disconnect } = useDisconnect();

  return (
    <header className="sticky top-0 z-50 w-full border-b border-white/5 bg-[#0B0E11]/80 backdrop-blur-md">
      <div className="container mx-auto px-4 h-16 flex items-center justify-between">
        <div className="flex items-center gap-8">
          <div className="flex items-center gap-2">
            <div className="w-8 h-8 bg-brand-primary rounded-lg flex items-center justify-center">
              <span className="text-black font-bold text-xl">M</span>
            </div>
            <span className="font-display font-bold text-xl hidden sm:block">MetaYield <span className="text-brand-primary">Vault</span></span>
          </div>
          
          <nav className="hidden md:flex items-center gap-6">
            <a href="#" className="text-sm font-medium text-white hover:text-brand-primary transition-colors">Dashboard</a>
            <a href="#" className="text-sm font-medium text-white/60 hover:text-white transition-colors">Vaults</a>
            <a href="#" className="text-sm font-medium text-white/60 hover:text-white transition-colors">Analytics</a>
            <a href="#" className="text-sm font-medium text-white/60 hover:text-white transition-colors">Governance</a>
          </nav>
        </div>

        <div className="flex items-center gap-4">
          <button className="p-2 text-white/60 hover:text-white transition-colors">
            <Bell size={20} />
          </button>
          
          {isConnected ? (
            <div className="flex items-center gap-2">
              <div className="hidden sm:flex flex-col items-end mr-2">
                <span className="text-[10px] text-white/40 font-mono">Connected</span>
                <span className="text-xs font-mono text-white/80">
                  {address?.slice(0, 6)}...{address?.slice(-4)}
                </span>
              </div>
              <button 
                onClick={() => disconnect()}
                className="p-2 text-white/40 hover:text-red-400 transition-colors bg-white/5 rounded-lg border border-white/10"
              >
                <LogOut size={16} />
              </button>
            </div>
          ) : (
            <button 
              onClick={() => connect({ connector: injected() })}
              className="btn-primary py-2 px-4 flex items-center gap-2 text-sm"
            >
              <Wallet size={16} />
              <span>Connect Wallet</span>
            </button>
          )}

          <button className="md:hidden p-2 text-white/60">
            <Menu size={24} />
          </button>
        </div>
      </div>
    </header>
  );
}
