'use client';
import { useEffect, useRef, useState } from 'react';
import { dieFace } from '../rules';
import type { GameProps } from '../GamePopup';

// Dice roll (0100): two dice tumble and settle. Every roll wins the prize the database drew; the dice are for show.
// With reduced motion they land at once.
const PIPS: Record<number, number[]> = { 1: [4], 2: [0, 8], 3: [0, 4, 8], 4: [0, 2, 6, 8], 5: [0, 2, 4, 6, 8], 6: [0, 2, 3, 5, 6, 8] };
function Die({ n, rolling }: { n: number; rolling: boolean }) {
  return (
    <span className={`ccg-die${rolling ? ' is-rolling' : ''}`} role="img" aria-label={`A die showing ${n}`}>
      {Array.from({ length: 9 }, (_, i) => <i key={i} className={PIPS[n]!.includes(i) ? 'is-on' : ''} />)}
    </span>
  );
}
export default function Dice({ prize, reduced, onReveal }: GameProps) {
  const [faces, setFaces] = useState<[number, number]>([1, 6]);
  const [state, setState] = useState<'idle' | 'rolling' | 'done'>('idle');
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);
  useEffect(() => () => timers.current.forEach(clearTimeout), []);
  function roll() {
    if (state !== 'idle') return;
    const end: [number, number] = [dieFace(Math.random), dieFace(Math.random)];
    if (reduced) { setFaces(end); setState('done'); timers.current.push(setTimeout(onReveal, 700)); return; }
    setState('rolling');
    for (let i = 0; i < 12; i++) timers.current.push(setTimeout(() => setFaces([dieFace(Math.random), dieFace(Math.random)]), i * 110));
    timers.current.push(setTimeout(() => { setFaces(end); setState('done'); }, 12 * 110 + 60));
    timers.current.push(setTimeout(onReveal, 12 * 110 + 1500));
  }
  return (
    <div className="ccg-stage">
      <div className="ccg-dice" aria-live="off">
        <Die n={faces[0]} rolling={state === 'rolling'} /><Die n={faces[1]} rolling={state === 'rolling'} />
      </div>
      <p className="ccg-live" aria-live="polite">{state === 'done' ? <>You rolled {faces[0]} and {faces[1]}. Every roll wins <b>{prize.label}</b></> : state === 'rolling' ? 'Rolling...' : 'Roll the dice. Every roll wins.'}</p>
      <button type="button" className="btn btn--primary ccg-play" onClick={roll} disabled={state !== 'idle'} data-testid="game-action">Roll the dice</button>
    </div>
  );
}
