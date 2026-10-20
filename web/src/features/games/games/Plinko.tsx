'use client';
import { useMemo, useRef, useState, useEffect } from 'react';
import { plinkoPath, plinkoSlots } from '../rules';
import type { GameProps } from '../GamePopup';

// Plinko: the disc bounces down 8 rows of pegs into one of 9 slots. The slot is the prize the database drew; the path
// stays near the middle (the biggest prizes) as long as it can, so it often passes close to them.
const ROWS = 8, W = 300, TOP = 26, GAP = 26, DX = W / (ROWS + 2);
export default function Plinko({ prize, prizes, reduced, onReveal }: GameProps) {
  const slots = useMemo(() => plinkoSlots(prizes, ROWS), [prizes]);
  const [step, setStep] = useState(-1);
  const [path, setPath] = useState<{ slot: number; moves: boolean[] } | null>(null);
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);
  useEffect(() => () => timers.current.forEach(clearTimeout), []);
  const H = TOP + GAP * (ROWS + 1) + 40;
  // where the disc is after `n` moves: x from the rights taken so far
  const at = (n: number) => {
    if (!path || n < 0) return { x: W / 2, y: 8 };
    const rights = path.moves.slice(0, n).filter(Boolean).length;
    return { x: W / 2 + (rights - n / 2) * DX, y: TOP + GAP * n + (n === ROWS ? 18 : 0) };
  };
  function drop() {
    if (path) return;
    const p = plinkoPath(slots, prize.key, Math.random);
    setPath(p);
    if (reduced) { setStep(ROWS); timers.current.push(setTimeout(onReveal, 700)); return; }
    for (let i = 0; i <= ROWS; i++) timers.current.push(setTimeout(() => setStep(i), 120 + i * 230));
    timers.current.push(setTimeout(onReveal, 120 + ROWS * 230 + 1500));
  }
  const d = at(step);
  const done = step === ROWS;
  return (
    <div className="ccg-stage">
      <div className="ccg-plinko">
        <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`A Plinko board with ${slots.length} prize slots: ${slots.map((s) => s.short).join(', ')}`}>
          <rect width={W} height={H} rx="14" fill="#000" />
          {Array.from({ length: ROWS }, (_, r) => Array.from({ length: r + 3 }, (_, k) => (
            <circle key={`${r}-${k}`} cx={W / 2 + (k - (r + 2) / 2) * DX} cy={TOP + GAP * r + GAP / 2} r="3.2" fill="#fff" opacity="0.85" />)))}
          {slots.map((s, i) => {
            const x = W / 2 + (i - ROWS / 2) * DX;
            const hit = done && path?.slot === i;
            return (<g key={i}>
              <rect x={x - DX / 2 + 2} y={H - 40} width={DX - 4} height="32" rx="5" fill={hit ? '#fff' : i === Math.floor(ROWS / 2) ? '#D0111B' : '#2a2a2a'} />
              <text x={x} y={H - 19} textAnchor="middle" fontSize="10.5" fontWeight="800" fill={hit ? '#D0111B' : '#fff'} fontFamily="inherit">{s.short}</text>
            </g>);
          })}
          <circle className="ccg-plinko__disc" cx="0" cy="0" r="9" fill="#D0111B" stroke="#fff" strokeWidth="2.5" style={{ transform: `translate(${d.x}px, ${d.y}px)` }} />
        </svg>
      </div>
      <p className="ccg-live" aria-live="polite">{done ? <>It landed on <b>{prize.label}</b></> : path ? 'Bouncing...' : ''}</p>
      <button type="button" className="btn btn--primary ccg-play" onClick={drop} disabled={Boolean(path)} data-testid="game-action">Drop the disc</button>
    </div>
  );
}
