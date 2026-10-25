'use client';
import { useEffect, useMemo, useRef, useState } from 'react';
import { slotStops, slotStrip } from '../rules';
import type { GameProps } from '../GamePopup';

// Slot machine (0100): three reels of the prize table's words spin and stop one after another on the drawn prize, three
// in a row on the middle line. The rare prizes are on the reels once each and often pass by just before a stop. With
// reduced motion the reels show the result at once.
const ROW = 44, REPEAT = 4;
export default function Slots({ prize, prizes, reduced, onReveal }: GameProps) {
  const strip = useMemo(() => slotStrip(prizes), [prizes]);
  const [stops, setStops] = useState<number[] | null>(null);
  const [stopped, setStopped] = useState(0);
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);
  useEffect(() => () => timers.current.forEach(clearTimeout), []);
  const L = strip.length;
  function pull() {
    if (stops) return;
    const s = slotStops(strip, prize.key, Math.random);
    setStops(s);
    if (reduced) { setStopped(3); timers.current.push(setTimeout(onReveal, 700)); return; }
    [1300, 1900, 2500].forEach((t, i) => timers.current.push(setTimeout(() => setStopped(i + 1), t)));
    timers.current.push(setTimeout(onReveal, 3700));
  }
  // the top row of the window: the stop sits on the middle row, in the last copies of the strip so the reel turns
  const top = (i: number) => (stops ? (REPEAT - 1) * L + stops[i]! - 1 : 0);
  const reels = [0, 1, 2];
  const done = stopped === 3;
  return (
    <div className="ccg-stage">
      <div className="ccg-slots" role="img" aria-label={done ? `Three reels showing ${prize.short}, ${prize.short}, ${prize.short}` : `Three slot reels with the prizes ${[...new Set(strip.map((s) => s.short))].join(', ')}`}>
        {reels.map((i) => (
          <div key={i} className="ccg-reel">
            <ul className="ccg-reel__strip" style={{ transform: `translateY(${-top(i) * ROW}px)`, transitionDuration: reduced || !stops ? '0ms' : `${1300 + i * 600}ms` }}>
              {Array.from({ length: REPEAT }, (_, k) => strip.map((s, j) => <li key={`${k}-${j}`} className={s.key === strip[0]!.key ? '' : 'is-big'} data-long={s.short.length > 4 || undefined}>{s.short}</li>))}
            </ul>
          </div>
        ))}
        <span className="ccg-slots__line" aria-hidden="true" />
      </div>
      <p className="ccg-live" aria-live="polite">{done ? <>Three in a row: <b>{prize.label}</b></> : stops ? 'Spinning...' : 'Pull the lever. Every spin wins.'}</p>
      <button type="button" className="btn btn--primary ccg-play" onClick={pull} disabled={Boolean(stops)} data-testid="game-action">Pull the lever</button>
    </div>
  );
}
