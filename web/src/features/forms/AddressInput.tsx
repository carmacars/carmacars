'use client';
import { useEffect, useRef, useState } from 'react';

// Address lookup while typing (prototype input[data-addr-lookup]): an ARIA combobox that asks the
// maps module through /api/address (Google Places Autocomplete in production, sample landmarks
// locally). Arrow keys and Enter choose; Escape closes. The chosen place id goes with the form.
export interface AddressValue { label: string; placeId: string }

export function AddressInput({ id, name, value, onChange, invalid, describedBy, required }: { id: string; name: string; value: AddressValue; onChange: (v: AddressValue) => void; invalid?: boolean; describedBy?: string; required?: boolean }) {
  const [items, setItems] = useState<{ id: string; label: string }[]>([]);
  const [idx, setIdx] = useState(-1);
  const session = useRef('');
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => () => clearTimeout(timer.current), []);
  const search = (q: string) => {
    clearTimeout(timer.current);
    if (q.trim().length < 2) { setItems([]); return; }
    session.current ||= crypto.randomUUID();
    timer.current = setTimeout(async () => {
      try {
        const r = await fetch(`/api/address?q=${encodeURIComponent(q)}&s=${session.current}`);
        const j = (await r.json()) as { items?: { id: string; label: string }[] };
        setItems(j.items ?? []); setIdx(-1);
      } catch { setItems([]); }
    }, 200);
  };
  const choose = (i: number) => { const it = items[i]; if (!it) return; onChange({ label: it.label, placeId: it.id }); setItems([]); setIdx(-1); session.current = ''; };
  const open = items.length > 0;
  return (
    <>
      <input className="input" id={id} name={name} type="text" autoComplete="off" role="combobox" aria-autocomplete="list" aria-expanded={open}
        aria-controls={`${id}-list`} aria-activedescendant={idx > -1 ? `${id}-list-${idx}` : undefined} aria-invalid={invalid || undefined} aria-describedby={describedBy}
        aria-required={required || undefined} value={value.label}
        onChange={(e) => { onChange({ label: e.target.value, placeId: '' }); search(e.target.value); }}
        onKeyDown={(e) => {
          if (!open) return;
          if (e.key === 'ArrowDown') { e.preventDefault(); setIdx(Math.min(items.length - 1, idx + 1)); }
          else if (e.key === 'ArrowUp') { e.preventDefault(); setIdx(Math.max(0, idx - 1)); }
          else if (e.key === 'Enter' && idx > -1) { e.preventDefault(); choose(idx); }
          else if (e.key === 'Escape') { e.preventDefault(); setItems([]); }
        }}
        onBlur={() => setTimeout(() => setItems([]), 150)} />
      <ul className="lookup" id={`${id}-list`} role="listbox" aria-label="Address suggestions" hidden={!open}>
        {items.map((it, i) => <li key={it.id} role="option" id={`${id}-list-${i}`} aria-selected={i === idx} onMouseDown={(e) => { e.preventDefault(); choose(i); }}>{it.label}</li>)}
      </ul>
    </>
  );
}
