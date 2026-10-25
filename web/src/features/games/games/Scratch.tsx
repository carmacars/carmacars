'use client';
import { useEffect, useRef, useState } from 'react';
import type { GameProps } from '../GamePopup';

// Scratch to reveal: a silver layer over the prize; scratch it with a finger or the mouse (half of it shows the
// prize), or press "Reveal it for me" (keyboard and screen readers).
export default function Scratch({ prize, reduced, onReveal }: GameProps) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const [gone, setGone] = useState(false);
  const down = useRef(false);
  const moves = useRef(0);
  const shown = useRef(false);

  useEffect(() => {
    const c = canvas.current;
    if (!c) return;
    const r = c.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    c.width = Math.round(r.width * dpr); c.height = Math.round(r.height * dpr);
    const x = c.getContext('2d');
    if (!x) return;
    x.scale(dpr, dpr);
    const g = x.createLinearGradient(0, 0, r.width, r.height);
    g.addColorStop(0, '#bdbdbd'); g.addColorStop(0.5, '#e9e9e9'); g.addColorStop(1, '#a9a9a9');
    x.fillStyle = g; x.fillRect(0, 0, r.width, r.height);
    x.fillStyle = '#555'; x.font = '700 16px system-ui, sans-serif'; x.textAlign = 'center';
    x.fillText('Scratch here', r.width / 2, r.height / 2 + 6);
  }, []);

  function reveal() {
    if (shown.current) return;
    shown.current = true;
    setGone(true);
    setTimeout(onReveal, reduced ? 600 : 1400);
  }
  function scratch(e: React.PointerEvent<HTMLCanvasElement>) {
    if (!down.current || shown.current) return;
    const c = canvas.current!, x = c.getContext('2d')!;
    const r = c.getBoundingClientRect();
    x.globalCompositeOperation = 'destination-out';
    x.beginPath(); x.arc(e.clientX - r.left, e.clientY - r.top, 18, 0, Math.PI * 2); x.fill();
    if (++moves.current % 8 === 0) {
      const d = x.getImageData(0, 0, c.width, c.height).data;
      let clear = 0, n = 0;
      for (let i = 3; i < d.length; i += 4 * 32) { n++; if (d[i] === 0) clear++; }
      if (clear / n > 0.45) reveal();
    }
  }
  return (
    <div className="ccg-stage">
      <div className="ccg-scratch">
        <p className="ccg-scratch__prize" aria-hidden={!gone}>{prize.short}<small>{prize.replay ? 'one more game' : 'off your rental'}</small></p>
        <canvas ref={canvas} className={gone ? 'is-gone' : ''} aria-hidden="true"
          onPointerDown={(e) => { down.current = true; e.currentTarget.setPointerCapture(e.pointerId); scratch(e); }}
          onPointerMove={scratch} onPointerUp={() => { down.current = false; }} onPointerCancel={() => { down.current = false; }} />
      </div>
      <p className="ccg-live" aria-live="polite">{gone ? <>You uncovered <b>{prize.label}</b></> : 'Scratch the silver layer to see your prize.'}</p>
      <button type="button" className="btn btn--ghost ccg-play" onClick={reveal} disabled={gone} data-testid="game-action">Reveal it for me</button>
    </div>
  );
}
