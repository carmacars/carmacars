'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { guidedAct } from '@/server/actions/guided';
import type { LicenceCheck, LicenceRead, PrimarySwap } from '@/features/admin/todo/types';

// The licence reader's lines for staff (release 31, D2; migration 0602): what was read, then each check as pass or flag.
// Shown on the document review and on the field and counter verify pages. Staff still approve (unless an Admin turned
// on automatic approval when every check passes). Never logged; the number shows here only.
export function LicenceChecks({ read, checks }: { read?: LicenceRead | null; checks?: LicenceCheck[] }) {
  if (!checks?.length || checks.every((c) => c.ok === null)) return read && Object.keys(read).length ? null : <p className="small muted" data-testid="licence-checks-none">Not read yet.</p>;
  return (
    <div className="stack" data-testid="licence-checks">
      {read && (read.full_name || read.issuer) && (
        <p className="small">Read from the {read.source === 'barcode' ? 'back’s barcode' : 'photo'}: {[read.full_name, read.date_of_birth && `born ${read.date_of_birth}`, read.licence_number,
          read.licence_class && `class ${read.licence_class}`, read.expires_on && `expires ${read.expires_on}`, read.issuer].filter(Boolean).join(' · ')}</p>)}
      <ul className="lc-lines">
        {checks.filter((c) => c.ok !== null).map((c) => (
          <li key={c.key} className={c.ok ? 'is-pass' : 'is-flag'} data-testid={`licence-check-${c.key}`} data-ok={c.ok ? 'pass' : 'flag'}>
            <span className={`badge ${c.ok ? 'badge--outline' : 'badge--red'}`}>{c.ok ? 'Pass' : 'Flag'}</span> {c.label}{c.detail ? `: ${c.detail}` : ''}
          </li>))}
      </ul>
    </div>
  );
}

const STATE: Record<PrimarySwap['state'], string> = { needed: 'Primary driver: Ontario licence needed. Pickup is blocked until it is met.', resolved: 'Met: the main driver holds an Ontario licence.',
  undone: 'Undone by an Admin: the first main driver is back.', overridden: 'Let go by an Admin' };

/** The swap, for staff: who was moved and why; an Admin can undo it or let it go with a reason. */
export function PrimarySwapPanel({ booking, swap, onDone, canDecide = true }: { booking: string; swap: PrimarySwap; onDone: (msg: { ok: boolean; text: string }) => void; canDecide?: boolean }) {
  const [reason, setReason] = useState('');
  const [pending, start] = useTransition();
  const decide = (action: 'undo' | 'override') => start(async () => {
    const r = await guidedAct('primary_swap_decide', { booking, action, reason: reason.trim() });
    onDone(r.ok ? { ok: true, text: action === 'undo' ? 'Undone: the first main driver is back.' : 'Let go: pickup can go ahead.' } : { ok: false, text: r.message });
  });
  return (
    <section className={`alert ${swap.state === 'needed' ? 'alert--warn' : ''} stack`} data-testid="primary-swap" data-state={swap.state}>
      <span className="alert__title">Main driver{swap.state === 'needed' ? ': Ontario licence needed' : ''}</span>
      <span>{swap.from_name ?? 'The main driver'}’s licence is from {swap.issuer ?? 'outside Ontario'}: moved to additional driver.{swap.to_name ? ` New main driver: ${swap.to_name}.` : ' No new main driver yet.'}</span>
      <span>{STATE[swap.state]}{swap.state === 'overridden' && swap.reason ? `: ${swap.reason}` : ''}</span>
      {swap.state === 'needed' && canDecide && (
        <details>
          <summary className="small" data-testid="primary-swap-admin">Admin: undo or let it go</summary>
          <div className="stack">
            <label className="label" htmlFor={`ps-${booking}`}>Reason (needed to let it go)</label>
            <input className="input" id={`ps-${booking}`} value={reason} onChange={(e) => setReason(e.target.value)} data-testid="primary-swap-reason" />
            <div className="row">
              <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => decide('undo')} data-testid="primary-swap-undo">Undo the swap</button>
              <button className="btn btn--ghost btn--sm" type="button" disabled={pending || reason.trim().length < 5} onClick={() => decide('override')} data-testid="primary-swap-override">Let it go</button>
            </div>
          </div>
        </details>)}
    </section>
  );
}

/** The same panel on a server-rendered page: the page is refreshed after a decision. */
export function PrimarySwapBox({ booking, swap, canDecide = true }: { booking: string; swap: PrimarySwap; canDecide?: boolean }) {
  const router = useRouter();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  return (<>
    <PrimarySwapPanel booking={booking} swap={swap} canDecide={canDecide} onDone={(m) => { setMsg(m); if (m.ok) router.refresh(); }} />
    {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
  </>);
}
