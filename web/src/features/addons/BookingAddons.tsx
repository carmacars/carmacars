'use client';
import { useRouter } from 'next/navigation';
import { useState, useTransition } from 'react';
import { money } from '@/lib/format';
import { staffAddonConfirm, staffAddonRemove } from '@/server/actions/addons';
import type { BookingAddon } from './model';

// A booking's add-ons for staff (migration 0066): confirm or decline one that waits (a chauffeur asked for after
// booking is charged on the Card on File when confirmed), remove one (unpaid: its line goes; paid: a refund for it
// awaits approval). On a request, staff change add-ons on the review screen instead.
export function BookingAddons({ items, status, refresh }: { items: BookingAddon[]; status: string; refresh: string[] }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState<string | null>(null);
  const [removing, setRemoving] = useState<string | null>(null);
  const [reason, setReason] = useState('');
  const live = ['confirmed', 'on_rent'].includes(status);
  if (!items.length) return <p className="small muted">No add-ons.</p>;
  const run = (f: () => Promise<{ ok: boolean; message?: string; data?: unknown }>, done: string) => start(async () => {
    const r = await f(); setMsg(r.ok ? done : (r.message ?? 'Not done.')); if (r.ok) { setRemoving(null); setReason(''); router.refresh(); }
  });
  return (
    <div className="stack" data-testid="booking-addons">
      <ul className="ad-list">{items.map((a) => (
        <li key={a.id} data-addon={a.code}>
          <b>{a.quantity > 1 ? `${a.quantity} x ` : ''}{a.name}</b>{a.hours ? `, ${+a.hours} hours` : ''}
          <span className="ad-sub">{a.amount_cents !== null ? money((a.amount_cents ?? 0) + (a.hst_cents ?? 0), { cents: true }) + ' with HST' : 'not charged yet'}
            {a.status === 'pending' ? ' · waiting for confirmation' : ''}{a.after_booking ? ' · added after booking' : ''}{a.paid ? ' · paid' : a.amount_cents !== null ? ' · unpaid' : ''}
            {a.prepaid_fuel ? ' · prepaid fuel' : ''}{a.kept_on_cancel ? ' · kept on the cancellation' : ''}</span>
          {live && a.status === 'pending' && <span className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }}>
            <button className="btn btn--primary btn--sm" type="button" disabled={pending} data-testid={`addon-confirm-${a.code}`}
              onClick={() => run(async () => { const r = await staffAddonConfirm(a.id, true, undefined, refresh); return r.ok ? { ok: true, message: r.data.message ?? undefined } : r; }, 'Confirmed.')}>Confirm{a.after_booking ? ' and charge' : ''}</button>
            <button className="btn btn--quiet btn--sm" type="button" disabled={pending}
              onClick={() => run(() => staffAddonConfirm(a.id, false, 'Not available', refresh), 'Declined.')}>Decline</button></span>}
          {live && a.status === 'confirmed' && removing !== a.id && <button className="btn btn--quiet btn--sm" type="button" onClick={() => setRemoving(a.id)} data-testid={`addon-remove-${a.code}`}>Remove</button>}
          {removing === a.id && (
            <form className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }} onSubmit={(e) => { e.preventDefault(); run(async () => { const r = await staffAddonRemove(a.id, reason, refresh);
              return r.ok ? { ok: true } : r; }, a.paid ? 'Removed. A refund for it awaits approval.' : 'Removed.'); }}>
              <label className="sr-only" htmlFor={`rm-${a.id}`}>Reason</label>
              <input className="input" id={`rm-${a.id}`} placeholder="Reason" value={reason} onChange={(e) => setReason(e.target.value)} required />
              <button className="btn btn--danger btn--sm" type="submit" disabled={pending || !reason.trim()}>Remove{a.paid ? ' and refund' : ''}</button>
              <button className="btn btn--quiet btn--sm" type="button" onClick={() => setRemoving(null)}>Cancel</button>
            </form>)}
        </li>))}</ul>
      {msg && <p className="small" role="status">{msg}</p>}
    </div>
  );
}
