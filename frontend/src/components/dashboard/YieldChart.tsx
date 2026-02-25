import React from 'react';
import { AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from 'recharts';

const data = [
  { date: '2024-01', yield: 12.5 },
  { date: '2024-02', yield: 13.8 },
  { date: '2024-03', yield: 15.2 },
  { date: '2024-04', yield: 14.9 },
  { date: '2024-05', yield: 16.5 },
  { date: '2024-06', yield: 18.4 },
];

export function YieldChart() {
  return (
    <div className="glass-panel p-6 h-[400px] flex flex-col">
      <div className="flex items-center justify-between mb-6">
        <h3 className="text-lg font-bold">Historical Performance (APY)</h3>
        <div className="flex gap-2">
          {['1W', '1M', '3M', '1Y', 'ALL'].map((p) => (
            <button key={p} className="text-xs px-2 py-1 rounded bg-white/5 hover:bg-white/10 transition-colors">
              {p}
            </button>
          ))}
        </div>
      </div>
      <div className="flex-1 w-full">
        <ResponsiveContainer width="100%" height="100%">
          <AreaChart data={data}>
            <defs>
              <linearGradient id="colorYield" x1="0" y1="0" x2="0" y2="1">
                <stop offset="5%" stopColor="#F3BA2F" stopOpacity={0.3}/>
                <stop offset="95%" stopColor="#F3BA2F" stopOpacity={0}/>
              </linearGradient>
            </defs>
            <CartesianGrid strokeDasharray="3 3" stroke="#ffffff10" vertical={false} />
            <XAxis 
              dataKey="date" 
              stroke="#ffffff40" 
              fontSize={12} 
              tickLine={false} 
              axisLine={false}
            />
            <YAxis 
              stroke="#ffffff40" 
              fontSize={12} 
              tickLine={false} 
              axisLine={false}
              tickFormatter={(value) => `${value}%`}
            />
            <Tooltip 
              contentStyle={{ backgroundColor: '#1E2329', border: 'none', borderRadius: '8px', color: '#fff' }}
            />
            <Area 
              type="monotone" 
              dataKey="yield" 
              stroke="#F3BA2F" 
              fillOpacity={1} 
              fill="url(#colorYield)" 
              strokeWidth={2}
            />
          </AreaChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}
