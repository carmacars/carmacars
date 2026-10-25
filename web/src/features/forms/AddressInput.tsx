'use client';
import { useEffect, useRef, useState } from 'react';
import type { AddressParts } from './address-parts';

// Address lookup while typing (prototype input[data-addr-lookup]): an ARIA combobox that asks the
// maps module through /api/address (Google Places Autocomplete in production, sample landmarks
// locally). Arrow keys and Enter choose; Escape closes. The chosen place id goes with the form.
// Google calls are capped a day (0113), so the field asks sparingly: from 3 characters, 350 ms after the last key, never
// twice for the same text, and a slower answer to an older text is dropped. One session token covers every suggestion
// of one lookup and goes with the chosen place (session), so the Place Details call at submit closes the same session.
export interface AddressValue { label: string; placeId: string; session?: string }
const MIN_CHARS = 3;
const DEBOUNCE_MS = 350;
type Item = { id: string; label: string };

// onParts (0130): the chosen place in its parts (street, unit, city, province, postal code, country), for forms that keep
// them field by field; one Place Details call, in the same session. Over the daily cap the field says to type it.
// geo (2026-10-24): the place's coordinates, for forms that keep them (the business address, the delivery origin).
// anywhere (2026-10-24): suggestions from every country, not only Canada (a staff member's home address abroad).
export function AddressInput({ id, name, value, onChange, invalid, describedBy, required, onParts, placeholder, testId, anywhere }: { id: string; name: string; value: AddressValue; onChange: (v: AddressValue) => void; invalid?: boolean; describedBy?: string; required?: boolean;
  onParts?: (p: AddressParts, label: string, geo?: { lat: number; lng: number }) => void; placeholder?: string; testId?: string; anywhere?: boolean }) {
  const [items, setItems] = useState<Item[]>([]);
  const [limited, setLimited] = useState(false);
  const [idx, setIdx] = useState(-1);
  const session = useRef('');
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const inflight = useRef<AbortController | undefined>(undefined);
  const seen = useRef(new Map<string, Item[]>());
  useEffect(() => () => { clearTimeout(timer.current); inflight.current?.abort(); }, []);
  const search = (raw: string) => {
    clearTimeout(timer.current);
    inflight.current?.abort();
    const q = raw.trim().replace(/\s+/g, ' ').toLowerCase();
    if (q.length < MIN_CHARS) { setItems([]); return; }
    const known = seen.current.get(q);
    if (known) { setItems(known); setIdx(-1); return; }
    session.current ||= crypto.randomUUID();
    timer.current = setTimeout(async () => {
      const ac = new AbortController();
      inflight.current = ac;
      try {
        const r = await fetch(`/api/address?q=${encodeURIComponent(q)}&s=${session.current}${anywhere ? '&w=1' : ''}`, { signal: ac.signal });
        const j = (await r.json()) as { items?: Item[]; limited?: boolean };
        const got = j.items ?? [];
        setLimited(!!j.limited);
        seen.current.set(q, got);
        setItems(got); setIdx(-1);
      } catch (e) { if ((e as Error).name !== 'AbortError') setItems([]); }
    }, DEBOUNCE_MS);
  };
  const choose = (i: number) => {
    const it = items[i]; if (!it) return;
    const sess = session.current || undefined;
    onChange({ label: it.label, placeId: it.id, session: sess });
    setItems([]); setIdx(-1); session.current = ''; seen.current.clear();
    if (onParts) {
      void fetch(`/api/address/place?id=${encodeURIComponent(it.id)}&s=${encodeURIComponent(sess ?? '')}`).then((r) => r.json())
        .then((j: { place?: { label: string; parts: AddressParts | null; lat?: number; lng?: number } | null }) => {
          if (j.place?.parts) onParts(j.place.parts, j.place.label, typeof j.place.lat === 'number' && typeof j.place.lng === 'number' ? { lat: j.place.lat, lng: j.place.lng } : undefined);
        })
        .catch(() => undefined);
    }
  };
  const open = items.length > 0;
  return (
    <>
      <input className="input" id={id} name={name} type="text" autoComplete="off" role="combobox" aria-autocomplete="list" aria-expanded={open}
        aria-controls={`${id}-list`} aria-activedescendant={idx > -1 ? `${id}-list-${idx}` : undefined} aria-invalid={invalid || undefined} aria-describedby={describedBy}
        aria-required={required || undefined} value={value.label} placeholder={placeholder} data-testid={testId}
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
      {limited && <span className="hint" role="status" data-testid={`${id}-limited`}>Address suggestions are paused for today: type the full address.</span>}
    </>
  );
}
