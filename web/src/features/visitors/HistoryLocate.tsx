'use client';
import { useState, type ReactNode } from 'react';
import { showOnMap } from '@/features/live-map/focus';

// A History card's icon (Release 26): pressed, the map brings the visit's lead to the middle and opens its card; an
// old visit with no lead on the map says so instead.
export function HistoryLocate({ id, renter, who, kind, children }: { id: string; renter: string | null; who: string; kind: string; children: ReactNode }) {
  const [none, setNone] = useState(false);
  return (
    <span className="vs-loc">
      <button type="button" className={`vs-av vs-av--${kind}`} aria-label={`${who}: show on the map`} data-testid="vh-locate"
        onClick={() => setNone(!showOnMap({ session_id: id, renter_id: renter }))}>{children}</button>
      {none && <span className="vs-loc__none small muted" role="status">Not on the map now</span>}
    </span>
  );
}
