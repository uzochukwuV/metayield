import React from 'react';
import { PieChart, Pie, Cell, ResponsiveContainer, Tooltip, Legend } from 'recharts';

const data = [
  { name: 'AsterDEX Earn', value: 60, color: '#F3BA2F' },
  { name: 'PancakeSwap LP', value: 30, color: '#1FC7D4' },
  { name: 'USDT Buffer', value: 10, color: '#27AE60' },
];

export function AllocationChart() {
  return (
    <div className="glass-panel p-6 h-[400px] flex flex-col">
      <h3 className="text-lg font-bold mb-6">Current Allocation</h3>
      <div className="flex-1 w-full">
        <ResponsiveContainer width="100%" height="100%">
          <PieChart>
            <Pie
              data={data}
              cx="50%"
              cy="50%"
              innerRadius={60}
              outerRadius={80}
              paddingAngle={5}
              dataKey="value"
            >
              {data.map((entry, index) => (
                <Cell key={`cell-${index}`} fill={entry.color} stroke="none" />
              ))}
            </Pie>
            <Tooltip 
              contentStyle={{ backgroundColor: '#1E2329', border: 'none', borderRadius: '8px', color: '#fff' }}
              itemStyle={{ color: '#fff' }}
            />
            <Legend verticalAlign="bottom" height={36}/>
          </PieChart>
        </ResponsiveContainer>
      </div>
      <div className="mt-4 space-y-2">
        <div className="flex justify-between text-sm">
          <span className="text-white/60">Strategy Mode</span>
          <span className="text-emerald-400 font-medium">NORMAL</span>
        </div>
        <div className="flex justify-between text-sm">
          <span className="text-white/60">Target Drift</span>
          <span className="text-white font-medium">0.42%</span>
        </div>
      </div>
    </div>
  );
}
