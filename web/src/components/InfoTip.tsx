'use client';
import { useEffect, useId, useLayoutEffect, useRef, useState } from 'react';
import { infoText } from '@/features/info/text';

// The "i" beside a field (Release 21b, item 7; first 0132): what the field is, in a sentence or two from the guides. A real
// button (aria-label "About <topic>", aria-expanded): a click, a tap or Enter/Space opens it; Escape closes it and puts the focus
// back on the button; a tap or a focus elsewhere closes it. The open text is a popover the button names (aria-controls,
// aria-describedby), kept inside the window on a phone. `text` or a key of the catalog (src/features/info/text.ts).
export function InfoTip({ text, k, topic, label, testId }: { text?: string; k?: string; topic?: string; label?: string; testId?: string }) {
  const body = text ?? (k ? infoText(k) : undefined);
  const [open, setOpen] = useState(false);
  const [shift, setShift] = useState(0);
  const id = useId();
  const box = useRef<HTMLSpanElement>(null);
  const btn = useRef<HTMLButtonElement>(null);
  const tip = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!open) return;
    const off = (e: Event) => { if (box.current && !box.current.contains(e.target as Node)) setOpen(false); };
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopPropagation(); setOpen(false); btn.current?.focus(); } };
    document.addEventListener('pointerdown', off); document.addEventListener('focusin', off); document.addEventListener('keydown', esc, true);
    return () => { document.removeEventListener('pointerdown', off); document.removeEventListener('focusin', off); document.removeEventListener('keydown', esc, true); };
  }, [open]);
  // keep the popover inside the window (a phone, a field near the right edge)
  useLayoutEffect(() => {
    if (!open || !tip.current) { setShift(0); return; }
    const r = tip.current.getBoundingClientRect();
    const vw = document.documentElement.clientWidth;
    if (r.right > vw - 8) setShift(Math.round(vw - 8 - r.right));
    else if (r.left < 8) setShift(Math.round(8 - r.left));
  }, [open]);
  if (!body) return null;
  const name = label ?? (topic ? `About ${topic}` : 'What is this?');
  return (
    <span className="info" ref={box}>
      <button type="button" ref={btn} className="info__btn" aria-label={name} aria-expanded={open} aria-controls={open ? id : undefined} aria-describedby={open ? id : undefined}
        data-testid={testId} onClick={(e) => { e.preventDefault(); e.stopPropagation(); setOpen((v) => !v); }}>i</button>
      {open && <span className="info__tip" role="tooltip" id={id} ref={tip} style={shift ? { transform: `translateX(${shift}px)` } : undefined}>{body}</span>}
    </span>
  );
}
