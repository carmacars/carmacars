'use client';
import { useEffect, useRef, useState } from 'react';
import { MYSTERY_BOXES } from '../rules';
import type { GameProps } from '../GamePopup';

// Mystery box (0100): three closed gift boxes; pick one and it shakes and opens on the prize the database drew. The
// other two stay shut. With reduced motion the box opens at once.
export default function Mystery({ prize, reduced, onReveal }: GameProps) {
  const [picked, setPicked] = useState<number | null>(null);
  const [open, setOpen] = useState(false);
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);
  useEffect(() => () => timers.current.forEach(clearTimeout), []);
  function pick(i: number) {
    if (picked !== null) return;
    setPicked(i);
    timers.current.push(setTimeout(() => setOpen(true), reduced ? 50 : 1100));
    timers.current.push(setTimeout(onReveal, reduced ? 700 : 2500));
  }
  return (
    <div className="ccg-stage">
      <div className="ccg-boxes">
        {Array.from({ length: MYSTERY_BOXES }, (_, i) => (
          <button key={i} type="button" className={`ccg-box${picked === i ? (open ? ' is-open' : ' is-shaking') : ''}`} onClick={() => pick(i)} disabled={picked !== null}
            aria-label={`Box ${i + 1} of ${MYSTERY_BOXES}`} data-testid={`game-box-${i + 1}`}>
            <span className="ccg-box__lid" aria-hidden="true" />
            <span className="ccg-box__base" aria-hidden="true">{picked === i && open ? <b>{prize.short}</b> : '?'}</span>
          </button>
        ))}
      </div>
      <p className="ccg-live" aria-live="polite">{open ? <>Box {picked! + 1} holds <b>{prize.label}</b></> : picked !== null ? 'Opening...' : 'Pick a box. Every box holds a discount.'}</p>
    </div>
  );
}
