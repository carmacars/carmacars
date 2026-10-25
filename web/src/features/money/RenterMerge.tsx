'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { renterMerge } from '@/server/actions/supply';

export type DuplicateRow = { id: string; legal_name: string; email: string | null; mobile: string | null; date_of_birth: string | null; bookings: number; why: string };

/** Possible duplicates of this renter (0145), each with Merge into this record: bookings, licences, cards, payments,
 *  documents and messages move here; the other record stays, blocked, in the history. */
export function RenterMerge({ renterId, name, rows }: { renterId: string; name: string; rows: DuplicateRow[] }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  if (!rows.length) return null;
  return (
    <section className="pt-card ad-card stack" aria-labelledby="rm-h" data-testid="renter-merge">
      <h2 className="d4" id="rm-h">Possible duplicates of {name} ({rows.length})</h2>
      <p className="small muted">The same person entered twice? Merge the other record into this one: its bookings, licences, cards, payments, documents and messages move here, and any detail missing here is filled from it. The other record stays, blocked, with the merge in both histories.</p>
      <ul className="stack" style={{ listStyle: 'none', padding: 0, margin: 0 }}>
        {rows.map((r) => (
          <li key={r.id} className="row" style={{ justifyContent: 'space-between', flexWrap: 'wrap' }} data-testid="renter-duplicate">
            <span><b>{r.legal_name}</b> <span className="small">{[r.email, r.mobile, r.date_of_birth].filter(Boolean).join(' · ')} · {r.bookings} booking{r.bookings === 1 ? '' : 's'}</span><br /><span className="small muted">{r.why}</span></span>
            <button className="btn btn--ghost btn--sm" type="button" disabled={pending} data-testid="renter-merge-go"
              onClick={() => { if (!window.confirm(`Merge ${r.legal_name} (${r.bookings} booking${r.bookings === 1 ? '' : 's'}) into ${name}? This cannot be undone from here.`)) return;
                start(async () => { const x = await renterMerge(renterId, r.id); setMsg(x.ok ? { ok: true, text: `Merged.${x.data.account_moved ? ' Their sign-in moved here too.' : ''}` } : { ok: false, text: x.message }); if (x.ok) router.refresh(); }); }}>Merge into this record</button>
          </li>))}
      </ul>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </section>
  );
}
