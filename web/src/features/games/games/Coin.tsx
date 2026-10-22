'use client';
import { useEffect, useRef, useState } from 'react';
import { coinFlip, type CoinSide } from '../rules';
import type { GameProps } from '../GamePopup';

// Coin flip (0100): call heads or tails, the CarmaCars coin spins in the air and lands. Right call or not, the prize is
// the one the database drew; the coin is for show. With reduced motion it lands at once.
export default function Coin({ prize, reduced, onReveal }: GameProps) {
  const [call, setCall] = useState<CoinSide | null>(null);
  const [side, setSide] = useState<CoinSide | null>(null);
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);
  useEffect(() => () => timers.current.forEach(clearTimeout), []);
  function flip(c: CoinSide) {
    if (call) return;
    const s = coinFlip(Math.random);
    setCall(c);
    timers.current.push(setTimeout(() => setSide(s), reduced ? 50 : 1700));
    timers.current.push(setTimeout(onReveal, reduced ? 700 : 3000));
  }
  const spinning = call !== null && side === null;
  return (
    <div className="ccg-stage">
      <div className={`ccg-coin${spinning && !reduced ? ' is-spinning' : ''}${side === 'tails' ? ' is-tails' : ''}`} aria-hidden="true">
        <span className="ccg-coin__face ccg-coin__heads">CC<small>Heads</small></span>
        <span className="ccg-coin__face ccg-coin__tails">★<small>Tails</small></span>
      </div>
      <p className="ccg-live" aria-live="polite">{side ? <>It landed on {side}. {side === call ? 'Good call!' : 'Not this time, but'} You win <b>{prize.label}</b></>
        : call ? `You called ${call}. Flipping...` : 'Call it: heads or tails?'}</p>
      <div className="ccg-row">
        <button type="button" className="btn btn--primary" onClick={() => flip('heads')} disabled={call !== null} data-testid="game-action">Heads</button>
        <button type="button" className="btn btn--ghost" onClick={() => flip('tails')} disabled={call !== null} data-testid="game-call-tails">Tails</button>
      </div>
    </div>
  );
}
