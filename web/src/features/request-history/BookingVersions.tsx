'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { Card } from '@/features/admin/ui';
import { offersDo } from '@/server/actions/offers';
import { balanceWords, versionLabel, type BookingVersion, type BookingVersions as Data, type RestorePreview } from './model';

// r45 (2861): a confirmed booking's versions (before its first change, then after each change), each with "Restore this
// version": a preview of the difference first, then the booking back to that version's dates, car, rental charge and fee
// lines as one change with the reason. The same checks as Edit (who may change bookings, the car free); never a payment.
const $ = (c: number | null | undefined) => money(Number(c ?? 0), { cents: true });
const at = (iso: string | null | undefined) => (iso ? when(iso) : '');

function Row({ v, booking, may }: { v: BookingVersion; booking: string; may: boolean }) {
  const router = useRouter();
  const [pv, setPv] = useState<RestorePreview | null>(null);
  const [reason, setReason] = useState('');
  const [tell, setTell] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, run] = useTransition();
  const preview = () => run(async () => {
    setMsg(null);
    const r = await offersDo<RestorePreview>('booking_version_restore', { booking, version: v.no, preview: true });
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setPv(r.data);
  });
  const restore = () => run(async () => {
    setMsg(null);
    const r = await offersDo<RestorePreview>('booking_version_restore', { booking, version: v.no, reason: reason.trim(), tell_renter: tell }, [`/admin/bookings/${booking}`, `/staff/bookings/${booking}`]);
    if (!r.ok) { setMsg({ ok: false, text: r.message }); return; }
    setPv(null); setReason('');
    setMsg({ ok: true, text: r.data.changed ? `Version ${v.no} restored. ${balanceWords(r.data.open_before_cents, r.data.open_after_cents, $)}` : (r.data.message ?? 'Nothing to change.') });
    router.refresh();
  });
  return (
    <li className="pt-card stack" style={{ gap: 'var(--s-2)' }} data-testid={`booking-version-${v.no}`}>
      <div className="pt-card__head"><b>{versionLabel(v)}</b><span className="small num">{$(v.total_cents)}</span></div>
      <p className="small">{at(v.pickup_at)} to {at(v.return_at)} · {v.billable_days} day{v.billable_days === 1 ? '' : 's'} · {v.vehicle ?? 'the car'} · rental {$(v.rental_charge_cents)}</p>
      {v.kind !== 'start' && <p className="small muted">{at(v.at)}{v.by ? `, ${v.by}` : ''}{v.reason ? `: ${v.reason}` : ''}</p>}
      {may && !v.current && !pv && <p><button type="button" className="btn btn--ghost btn--sm" onClick={preview} disabled={pending} data-testid={`version-restore-${v.no}`}>{pending ? 'Working it out' : 'Restore this version'}</button></p>}
      {pv && (pv.ok && pv.changed ? (
        <div className="stack small" data-testid={`version-preview-${v.no}`}>
          <p><b>What changes:</b> {pv.before && pv.after ? <>{at(pv.before.pickup_at)} to {at(pv.before.return_at)} becomes {at(pv.after.pickup_at)} to {at(pv.after.return_at)}{pv.before.vehicle !== pv.after.vehicle ? `; ${pv.before.vehicle} becomes ${pv.after.vehicle}` : ''}; rental {$(pv.before.rental_charge_cents)} becomes {$(pv.after.rental_charge_cents)}.</> : null}{' '}
            Total {$(pv.total_before_cents)} becomes {$(pv.total_after_cents)}. {balanceWords(pv.open_before_cents, pv.open_after_cents, $)}</p>
          {pv.fees_kept && <p className="muted">This version was kept before its fees were: the dates, the car and the rental charge go back, the fees stay as they are now.</p>}
          {!!pv.unmatched?.length && <p className="muted">These fees cannot be set back exactly: {pv.unmatched.join(', ')}. Change them with Edit.</p>}
          <div className="field"><label className="label" htmlFor={`vr-why-${v.no}`}>Why (kept with the change)</label>
            <input className="input" id={`vr-why-${v.no}`} value={reason} onChange={(e) => setReason(e.target.value)} data-testid={`version-reason-${v.no}`} /></div>
          <label className="check"><input type="checkbox" checked={tell} onChange={(e) => setTell(e.target.checked)} /> <span>Tell the renter what changed</span></label>
          <div className="row"><button type="button" className="btn btn--primary btn--sm" onClick={restore} disabled={pending || reason.trim().length < 3} data-testid={`version-confirm-${v.no}`}>{pending ? 'Restoring' : `Restore version ${v.no}`}</button>
            <button type="button" className="btn btn--quiet btn--sm" onClick={() => setPv(null)}>Cancel</button></div>
        </div>
      ) : <p className={pv.ok ? 'small muted' : 'error'} role="status">{pv.ok ? pv.message ?? 'The booking is already as in this version.' : pv.problem}{' '}<button type="button" className="link small" onClick={() => setPv(null)}>Close</button></p>)}
      {msg && <p className={msg.ok ? 'small' : 'error'} role="status">{msg.text}</p>}
    </li>
  );
}

/** The versions card: shown once a confirmed booking has been changed. */
export function BookingVersions({ x }: { x: Data }) {
  if (x.versions.length < 2) return null;
  return (
    <Card title="Versions of this booking" testId="booking-versions" aside={<span className="small muted">{x.versions.length} versions</span>}>
      {!x.may_restore && x.refusal && <p className="small muted">{x.refusal}</p>}
      <ol className="stack" style={{ listStyle: 'none', padding: 0 }}>{[...x.versions].reverse().map((v) => <Row key={v.no} v={v} booking={x.booking_number} may={x.may_restore} />)}</ol>
      {x.may_restore && <p className="small muted">Restore puts the dates, the car, the rental charge and the fees back as they were in that version, after a preview. It is one more change in the history; payments are not touched, and any difference is a balance or a credit.</p>}
    </Card>
  );
}
