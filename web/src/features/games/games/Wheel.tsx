'use client';
import { useMemo, useRef, useState } from 'react';
import { shortScale, wheelSlices, wheelStop } from '../rules';
import type { GameProps } from '../GamePopup';

// Spin the wheel: 12 slices (the prizes of the table, the most common one on every other slice). The database drew the
// prize; the wheel turns five times and stops inside a slice showing it, often close to a bigger one.
const COLORS = ['#000000', '#D0111B', '#FFFFFF'];
export default function Wheel({ prize, prizes, reduced, onReveal }: GameProps) {
  const slices = useMemo(() => wheelSlices(prizes), [prizes]);
  const [deg, setDeg] = useState(0);
  const [state, setState] = useState<'idle' | 'spinning' | 'done'>('idle');
  const doneRef = useRef(false);
  const size = 360 / slices.length;
  const finish = () => { if (doneRef.current) return; doneRef.current = true; setState('done'); setTimeout(onReveal, reduced ? 600 : 1500); };
  function spin() {
    if (state !== 'idle') return;
    const { degrees } = wheelStop(slices, prize.key, Math.random);
    setState('spinning');
    setDeg(degrees);
    if (reduced) setTimeout(finish, 50);
    else setTimeout(finish, 5200); // in case the transition end is missed
  }
  const arc = (i: number) => {
    const a0 = ((i * size - 90) * Math.PI) / 180, a1 = (((i + 1) * size - 90) * Math.PI) / 180;
    return `M100,100 L${100 + 96 * Math.cos(a0)},${100 + 96 * Math.sin(a0)} A96,96 0 0,1 ${100 + 96 * Math.cos(a1)},${100 + 96 * Math.sin(a1)} Z`;
  };
  return (
    <div className="ccg-stage">
      <div className="ccg-wheel">
        <span className="ccg-wheel__pin" aria-hidden="true" />
        <svg viewBox="0 0 200 200" role="img" aria-label={`A prize wheel with ${slices.length} slices: ${[...new Set(slices.map((s) => s.label))].join(', ')}`}>
          <g className="ccg-wheel__disc" style={{ transform: `rotate(${deg}deg)`, transition: reduced || state === 'idle' ? 'none' : 'transform 5s cubic-bezier(0.12, 0.6, 0.1, 1)' }}
            onTransitionEnd={finish}>
            <circle cx="100" cy="100" r="99" fill="#000" />
            {slices.map((s, i) => {
              const fill = s.key === slices[0]!.key ? (i % 4 === 0 ? COLORS[0] : COLORS[2]) : COLORS[1];
              const text = fill === COLORS[2] ? '#000' : '#fff';
              const mid = i * size + size / 2;
              return (<g key={i}>
                <path d={arc(i)} fill={fill} stroke="#000" strokeWidth="1" />
                <text x="100" y="30" transform={`rotate(${mid} 100 100)`} textAnchor="middle" fontSize={13 * shortScale(s.short)} fontWeight="800" fill={text} fontFamily="inherit">{s.short}</text>
              </g>);
            })}
            <circle cx="100" cy="100" r="16" fill="#fff" stroke="#000" strokeWidth="3" />
          </g>
        </svg>
      </div>
      <p className="ccg-live" aria-live="polite">{state === 'spinning' ? 'Spinning...' : state === 'done' ? <>It stopped on <b>{prize.label}</b></> : ''}</p>
      <button type="button" className="btn btn--primary ccg-play" onClick={spin} disabled={state !== 'idle'} data-testid="game-action">Spin the wheel</button>
    </div>
  );
}
