'use client';
import { useCallback, useEffect, useState, type CSSProperties, type RefObject } from 'react';
import { inBounds, MAX_BOUNDS } from './config';
import type { PersonSpec } from './engine';
import { colourOfPerson, countPeople, filtersFor, initials, personLabel, visiblePeople, type PeopleFilter, type PeopleView } from './people';

// The people layer of every map that has one (migration 3350, release 48 part MAP): the Live map (Admin, and the staff
// Visitors page of customer service and Sales) and Fleet tracking (Admin, and the Fleet staff's car map). Read with the
// map's own refresh; the database decides who this reader sees (Admin and Fleet everyone, customer service and Sales the
// renters at a pickup or return, anyone else no one: then no chips are drawn at all).
export function usePeople(engine: RefObject<{ setPeople(p: PersonSpec[]): void } | null>, ready: boolean, everyMs: number, enabled = true) {
  const [people, setPeople] = useState<PeopleView | null>(null);
  const [on, setOn] = useState(true);
  const [hidden, setHidden] = useState<Set<PeopleFilter>>(new Set());

  const refresh = useCallback(async () => {
    try {
      const r = await fetch('/api/staff/live-people', { cache: 'no-store', credentials: 'same-origin' });
      setPeople(r.ok ? ((await r.json()) as PeopleView) : null);
    } catch { setPeople(null); }
  }, []);
  useEffect(() => {
    if (!enabled) return;
    const first = setTimeout(() => void refresh(), 0);
    const t = setInterval(() => { if (document.visibilityState === 'visible') void refresh(); }, everyMs);
    return () => { clearTimeout(first); clearInterval(t); };
  }, [refresh, everyMs, enabled]);

  useEffect(() => {
    const e = engine.current;
    if (!e || !ready) return;
    e.setPeople(on ? visiblePeople(people, hidden).filter((p) => inBounds(p.lng, p.lat, MAX_BOUNDS)).map((p): PersonSpec => ({
      id: p.id, lng: p.lng, lat: p.lat, colour: colourOfPerson(p), label: personLabel(p), initials: initials(p.name), kind: p.kind, job: p.reason === 'job'
    })) : []);
  }, [engine, ready, people, hidden, on]);

  const filters = filtersFor(people?.scope);
  const counts = countPeople(people);
  const chips = filters.length > 0 ? (
    <>
      <label data-testid="lm-people-layer"><input type="checkbox" checked={on} onChange={(e) => setOn(e.target.checked)} /> People ({people?.people.length ?? 0})</label>
      {on && filters.length > 1 && filters.map((f) => (
        <label key={f.key} className="lm-layers__sub" data-testid={`lm-people-${f.key}`}>
          <input type="checkbox" checked={!hidden.has(f.key)} onChange={(e) => setHidden((h) => { const n = new Set(h); if (e.target.checked) n.delete(f.key); else n.add(f.key); return n; })} />
          <span className="lm-dot" style={{ '--c': f.colour } as CSSProperties} aria-hidden="true" /> {f.label} ({counts[f.key]})
        </label>))}
    </>
  ) : null;
  return { people, chips, refresh };
}
