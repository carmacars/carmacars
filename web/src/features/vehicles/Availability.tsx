'use client';
import { useEffect, useState } from 'react';
import { browserRpc } from '@/lib/browser-rpc';
import { addDays, torontoInstant, torontoToday } from '@/lib/dates';

// Live availability under each car of a vehicle page's inventory block (migration 0092): one public.search_available
// call per page view, for a day from tomorrow at 10:00, shared by every card. The page itself stays static and cached.
let shared: Promise<Set<string> | null> | null = null;
function freeTomorrow(): Promise<Set<string> | null> {
  if (!shared) {
    const d = addDays(torontoToday(), 1);
    shared = browserRpc<Array<{ vehicle_id: string }>>('search_available', { p_pickup: torontoInstant(d, '10:00'), p_return: torontoInstant(addDays(d, 1), '10:00'), p_filters: {} })
      .then((rows) => new Set(rows.map((r) => r.vehicle_id))).catch(() => null);
  }
  return shared;
}

export function Availability({ id }: { id: string }) {
  const [free, setFree] = useState<boolean | null>(null);
  useEffect(() => {
    let live = true;
    void freeTomorrow().then((s) => { if (live && s) setFree(s.has(id)); });
    return () => { live = false; };
  }, [id]);
  return (
    <p className="vp-avail small" data-testid="vp-availability" aria-live="polite">
      {free === null ? <span className="muted">Checking tomorrow…</span> : free ? <span className="vp-avail__free">Free tomorrow</span> : <span className="muted">Booked tomorrow, other dates may be free</span>}
    </p>
  );
}
