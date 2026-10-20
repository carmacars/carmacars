'use client';
import { useEffect, useRef, useState } from 'react';
import { cupSwaps } from '../rules';
import type { GameProps } from '../GamePopup';

// Cup shuffle: the ball goes under the middle cup, the cups swap places for about three seconds, then the visitor picks
// one. Every cup hides a prize: whichever is picked shows the prize the database drew.
const X = ['0%', '116.67%', '233.33%']; // the three places, in cup widths (each cup is 30% wide, 5% apart)
export default function Cups({ prize, reduced, onReveal }: GameProps) {
  // place of each cup (cup i sits at place[i])
  const [place, setPlace] = useState([0, 1, 2]);
  const [phase, setPhase] = useState<'show' | 'shuffling' | 'pick' | 'done'>('show');
  const [picked, setPicked] = useState<number | null>(null);
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);
  useEffect(() => () => timers.current.forEach(clearTimeout), []);

  function shuffle() {
    const swaps = cupSwaps(Math.random);
    setPhase('shuffling');
    if (reduced) {
      let p = [0, 1, 2];
      for (const [a, b] of swaps) p = p.map((x) => (x === a ? b : x === b ? a : x));
      setPlace(p); setPhase('pick');
      return;
    }
    swaps.forEach(([a, b], i) => {
      timers.current.push(setTimeout(() => setPlace((p) => p.map((x) => (x === a ? b : x === b ? a : x))), 400 + i * 400));
    });
    timers.current.push(setTimeout(() => setPhase('pick'), 400 + swaps.length * 400 + 200));
  }
  function pick(cup: number) {
    if (phase !== 'pick') return;
    setPicked(cup); setPhase('done');
    timers.current.push(setTimeout(onReveal, reduced ? 700 : 1600));
  }
  // while they move the cups keep their order in the page (so they glide); to pick, left to right for the keyboard
  const order = phase === 'pick' || phase === 'done' ? [0, 1, 2].sort((a, b) => place[a]! - place[b]!) : [0, 1, 2];
  return (
    <div className="ccg-stage">
      <div className="ccg-cups" aria-hidden={phase === 'shuffling'}>
        {order.map((cup) => {
          const up = (phase === 'show' && cup === 1) || picked === cup;
          return (
            <button key={cup} type="button" className={`ccg-cup${up ? ' is-up' : ''}`} style={{ transform: `translateX(${X[place[cup]!]})`, left: 0 }}
              disabled={phase !== 'pick'} onClick={() => pick(cup)} aria-label={`Cup ${place[cup]! + 1} of 3`} data-testid={`game-cup-${place[cup]! + 1}`}>
              {(cup === 1 && phase === 'show') || picked === cup ? <span className="ccg-ball" aria-hidden="true">●</span> : null}
              {picked === cup && <span className="ccg-cup__prize">{prize.short}</span>}
              <span className="ccg-cup__shape" />
            </button>);
        })}
      </div>
      <p className="ccg-live" aria-live="polite">{phase === 'show' ? 'The ball is under the middle cup.' : phase === 'shuffling' ? 'Shuffling...' : phase === 'pick' ? 'Pick a cup.' : <>You found <b>{prize.label}</b></>}</p>
      {phase === 'show' && <button type="button" className="btn btn--primary ccg-play" onClick={shuffle} data-testid="game-action">Shuffle the cups</button>}
    </div>
  );
}
