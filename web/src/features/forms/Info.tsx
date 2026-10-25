'use client';
import { useEffect, useId, useRef, useState } from 'react';

// A small (i) beside a field or a price line (0132): what it is and how it is worked out. A real button: a tap or a
// click opens it, Escape or a tap elsewhere closes it; the field names the text with aria-describedby when it is open.
export function Info({ text, label = 'What is this?' }: { text: string; label?: string }) {
  const [open, setOpen] = useState(false);
  const id = useId();
  const box = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!open) return;
    const off = (e: Event) => { if (box.current && !box.current.contains(e.target as Node)) setOpen(false); };
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('pointerdown', off); document.addEventListener('keydown', esc);
    return () => { document.removeEventListener('pointerdown', off); document.removeEventListener('keydown', esc); };
  }, [open]);
  return (
    <span className="info" ref={box}>
      <button type="button" className="info__btn" aria-label={label} aria-expanded={open} aria-describedby={open ? id : undefined} onClick={() => setOpen((v) => !v)}>i</button>
      {open && <span className="info__tip" role="tooltip" id={id}>{text}</span>}
    </span>
  );
}
