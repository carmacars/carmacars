'use client';
import { useEffect, useRef, useState } from 'react';
import type { GameProps } from '../GamePopup';

// Prize drop (0100): a CarmaCars capsule machine. Turn the handle, a capsule drops down the chute, bounces and pops
// open on the prize the database drew. With reduced motion it drops and opens at once.
export default function Drop({ prize, reduced, onReveal }: GameProps) {
  const [phase, setPhase] = useState<'idle' | 'turning' | 'dropped' | 'open'>('idle');
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);
  useEffect(() => () => timers.current.forEach(clearTimeout), []);
  function turn() {
    if (phase !== 'idle') return;
    if (reduced) { setPhase('open'); timers.current.push(setTimeout(onReveal, 700)); return; }
    setPhase('turning');
    timers.current.push(setTimeout(() => setPhase('dropped'), 900));
    timers.current.push(setTimeout(() => setPhase('open'), 2100));
    timers.current.push(setTimeout(onReveal, 3300));
  }
  return (
    <div className="ccg-stage">
      <div className={`ccg-drop is-${phase}`} aria-hidden="true">
        <span className="ccg-drop__globe">{Array.from({ length: 7 }, (_, i) => <i key={i} style={{ ['--k' as string]: i }} />)}</span>
        <span className="ccg-drop__body"><span className="ccg-drop__handle" /><span className="ccg-drop__chute" /></span>
        <span className="ccg-drop__capsule"><span className="ccg-drop__top" /><span className="ccg-drop__prize">{phase === 'open' ? prize.short : ''}</span><span className="ccg-drop__bottom" /></span>
      </div>
      <p className="ccg-live" aria-live="polite">{phase === 'open' ? <>Your capsule holds <b>{prize.label}</b></> : phase === 'idle' ? 'Turn the handle for a prize capsule.' : 'Here it comes...'}</p>
      <button type="button" className="btn btn--primary ccg-play" onClick={turn} disabled={phase !== 'idle'} data-testid="game-action">Turn the handle</button>
    </div>
  );
}
