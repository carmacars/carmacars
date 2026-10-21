'use client';
import { useEffect, useMemo, useRef, useState } from 'react';
import { packCards, tearProgress, TORN } from '../rules';
import type { GameProps } from '../GamePopup';

// The card pack (0076): a sealed CarmaCars foil pack. The visitor tears the strip along the top (drag across it, tap it
// a few times, or press the button); five cards fan out and turn one by one, and the last one is the prize the
// database drew. A rare prize turns as a holographic card. CarmaCars' own picture cards only, never a real trading
// card design or brand. With reduced motion the pack opens and every card shows at once.
const FLIP_MS = 520;
export default function Pack({ prize, reduced, onReveal }: GameProps) {
  const cards = useMemo(() => packCards(Math.random), []);
  const [torn, setTorn] = useState(0);
  const [open, setOpen] = useState(false);
  const [shown, setShown] = useState(0); // cards turned over
  const drag = useRef<{ x0: number; w: number; moved: boolean } | null>(null);
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);
  useEffect(() => () => timers.current.forEach(clearTimeout), []);

  function tearOpen() {
    if (open) return;
    setTorn(1); setOpen(true);
    if (reduced) { setShown(cards.length); timers.current.push(setTimeout(onReveal, 600)); return; }
    cards.forEach((_, i) => timers.current.push(setTimeout(() => setShown(i + 1), 450 + i * FLIP_MS)));
    timers.current.push(setTimeout(onReveal, 450 + cards.length * FLIP_MS + 1100));
  }
  const tear = (t: number) => { setTorn(t); if (t >= TORN) tearOpen(); };
  const onDown = (e: React.PointerEvent<HTMLButtonElement>) => {
    if (open) return;
    e.currentTarget.setPointerCapture?.(e.pointerId);
    drag.current = { x0: e.clientX, w: e.currentTarget.getBoundingClientRect().width, moved: false };
  };
  const onMove = (e: React.PointerEvent<HTMLButtonElement>) => {
    const d = drag.current;
    if (!d || open) return;
    const t = tearProgress(d.x0, e.clientX, d.w);
    if (t > 0.04) d.moved = true;
    if (t > torn) tear(t);
  };
  const onUp = () => { drag.current = null; };
  // a tap (or Enter on the strip) tears a third
  const onTap = () => { if (!open && !drag.current?.moved) tear(Math.min(1, torn + 0.34)); };

  const last = shown === cards.length;
  const now = shown > 0 ? cards[shown - 1] : null;
  return (
    <div className="ccg-stage">
      <div className={`ccg-pack${open ? ' is-open' : ''}`}>
        {!open && (
          <div className="ccg-pack__sealed" style={{ ['--torn' as string]: torn }}>
            <button type="button" className="ccg-pack__strip" aria-label="Tear the strip along the top of the pack" onPointerDown={onDown} onPointerMove={onMove}
              onPointerUp={onUp} onPointerCancel={onUp} onClick={onTap}><span className="ccg-pack__tear" aria-hidden="true" /></button>
            <div className="ccg-pack__face" aria-hidden="true">
              <span className="ccg-pack__brand">Carma<b>Cars</b></span>
              <span className="ccg-pack__sub">Discount pack</span>
              <span className="ccg-pack__count">5 cards inside</span>
            </div>
          </div>
        )}
        {open && (
          <ol className="ccg-pack__fan" aria-label="The cards in the pack">
            {cards.map((c, i) => {
              const up = i < shown;
              const prizeCard = c.kind === 'prize';
              return (
                <li key={i} className={`ccg-pcard${up ? ' is-up' : ''}${prizeCard ? ' is-prize' : ''}${prizeCard && prize.rare ? ' is-holo' : ''}`}
                  style={{ ['--i' as string]: i, ['--n' as string]: cards.length, ['--h' as string]: c.kind === 'art' ? c.hue : 0 }}>
                  <span className="ccg-pcard__back" aria-hidden="true">CC</span>
                  <span className="ccg-pcard__front">
                    {c.kind === 'art' ? <><span className="ccg-pcard__art" aria-hidden="true" /><span className="ccg-pcard__title">{c.title}</span></>
                      : <><span className="ccg-pcard__win">{prize.short}</span><span className="ccg-pcard__title">{prize.label}</span></>}
                  </span>
                </li>
              );
            })}
          </ol>
        )}
      </div>
      <p className="ccg-live" aria-live="polite">{last ? <>The last card: <b>{prize.label}</b></> : now?.kind === 'art' ? `Card ${shown} of ${cards.length}: ${now.title}` : open ? 'Opening the pack...' : torn > 0 ? 'Keep tearing along the top' : 'Tear the strip along the top, or press the button'}</p>
      <button type="button" className="btn btn--primary ccg-play" onClick={tearOpen} disabled={open} data-testid="game-action">Tear it open</button>
    </div>
  );
}
