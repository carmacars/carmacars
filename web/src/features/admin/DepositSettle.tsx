'use client';
import { useId, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { opsAct, opsRead } from '@/server/actions/ops';

// The guided Deposit settlement (docs/blueprint/03-admin.md section 11, migration 0020's app.settle_deposit):
// what is owed is taken from the Deposit first, an amount may be held back for a pending claim, toll or
// ticket (with its reason, at most the set number of days after Check-in), and the rest goes back to the
// renter. The form shows the arithmetic before anything moves; the database decides, and sends a release
// above the person's limit to an Admin.
interface Preview {
  booking_number: string; status: string; has_statement: boolean; available_cents: number; due_cents: number; apply_cents: number; shortfall_cents: number;
  hold_back_max_cents: number; hold_back_until_max: string | null; holdback_days: number; may_release_without_approval: boolean;
  deposit: { status: string; amount_cents: number; applied_cents: number; held_back_cents: number; held_back_reason: string | null; held_back_until: string | null; released_cents: number } | null;
}
const $ = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const REASONS: Array<[string, string]> = [['pending_claim', 'A damage claim is pending'], ['pending_toll', 'A toll is expected'], ['pending_ticket', 'A ticket or fine is expected'], ['other', 'Something else']];

export function DepositSettle({ bookingId, refresh = [] }: { bookingId: string; refresh?: string[] }) {
  const id = useId().replace(/:/g, '');
  const dlg = useRef<HTMLDialogElement>(null);
  const router = useRouter();
  const [pv, setPv] = useState<Preview | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [hold, setHold] = useState('0.00');
  const [why, setWhy] = useState('pending_claim');
  const [detail, setDetail] = useState('');
  const [until, setUntil] = useState('');
  const [done, setDone] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const open = () => start(async () => {
    setErr(null); setDone(null);
    const r = await opsRead<Preview>('deposit_preview', { booking: bookingId });
    if (!r.ok) { setErr(r.message); dlg.current?.showModal(); return; }
    setPv(r.data); setHold(((r.data.deposit?.held_back_cents ?? 0) / 100).toFixed(2)); setUntil(r.data.deposit?.held_back_until ?? r.data.hold_back_until_max ?? '');
    dlg.current?.showModal();
  });
  const holdCents = Math.max(0, Math.round(Number(hold.replace(/[$,\s]/g, '')) * 100) || 0);
  const tooMuch = pv ? holdCents > pv.hold_back_max_cents : false;
  const release = pv ? Math.max(0, pv.available_cents - pv.apply_cents - holdCents) : 0;
  const submit = () => start(async () => {
    setErr(null);
    if (tooMuch) { setErr(`At most ${$(pv!.hold_back_max_cents)} can be held back.`); return; }
    if (holdCents > 0 && !detail.trim()) { setErr('Say what the hold-back is for (the claim, toll or ticket).'); return; }
    const reason = holdCents > 0 ? `${REASONS.find((x) => x[0] === why)?.[1] ?? why}: ${detail.trim()}` : null;
    const r = await opsAct<{ approval_needed?: boolean; actions?: unknown[] }>('deposit_settle', { booking: bookingId, hold_back_cents: holdCents, hold_back_reason: reason, hold_back_until: holdCents > 0 ? until || null : null }, refresh);
    if (!r.ok) { setErr(r.message); return; }
    setDone(r.data?.approval_needed ? 'Sent to an Admin to approve the release.' : 'Settled.');
    router.refresh();
  });
  return (
    <>
      <button className="btn btn--ghost btn--sm" type="button" onClick={open} disabled={pending} data-testid="deposit-settle">Settle the deposit</button>
      <dialog ref={dlg} className="ad-dialog" aria-labelledby={`${id}-t`}>
        <h2 className="d4" id={`${id}-t`}>Settle the deposit</h2>
        {pv && <form className="ad-form" noValidate onSubmit={(e) => { e.preventDefault(); submit(); }} data-testid="deposit-form">
          <dl className="pt-dl ad-kv">
            <div><dt>Deposit</dt><dd>{pv.deposit ? `${$(pv.deposit.amount_cents)} (${pv.deposit.status.replace(/_/g, ' ')})` : 'None taken'}</dd></div>
            <div><dt>Still available</dt><dd>{$(pv.available_cents)}</dd></div>
            <div><dt>Charges owed from the statement</dt><dd>{$(pv.due_cents)}</dd></div>
            <div><dt>Taken from the deposit for them</dt><dd>{$(pv.apply_cents)}</dd></div>
            {pv.shortfall_cents > 0 && <div><dt>Charged to the card on file</dt><dd>{$(pv.shortfall_cents)}</dd></div>}
          </dl>
          {!pv.has_statement && <p className="alert alert--error" role="alert"><span>Issue the Check-in statement first (Overview, Issue final statement).</span></p>}
          <div className="ad-fields">
            <div className={`field ad-field${tooMuch ? ' has-error' : ''}`}><label className="label" htmlFor={`${id}-h`}>Hold back ($)</label>
              <input className="input" id={`${id}-h`} inputMode="decimal" value={hold} onChange={(e) => setHold(e.target.value)} aria-describedby={`${id}-hh`} />
              <p className="hint" id={`${id}-hh`}>Up to {$(pv.hold_back_max_cents)}, for at most {pv.holdback_days} days after Check-in.</p></div>
            {holdCents > 0 && <>
              <div className="field ad-field"><label className="label" htmlFor={`${id}-r`}>Why</label>
                <select className="select" id={`${id}-r`} value={why} onChange={(e) => setWhy(e.target.value)}>{REASONS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
              <div className="field ad-field ad-field--wide"><label className="label" htmlFor={`${id}-d`}>What it is (claim, toll or ticket)</label>
                <input className="input" id={`${id}-d`} value={detail} onChange={(e) => setDetail(e.target.value)} placeholder="Rear bumper scuff, estimate requested" /></div>
              <div className="field ad-field"><label className="label" htmlFor={`${id}-u`}>Hold until</label>
                <input className="input" id={`${id}-u`} type="date" value={until} max={pv.hold_back_until_max ?? undefined} onChange={(e) => setUntil(e.target.value)} /></div>
            </>}
          </div>
          <p className="ad-tie" data-testid="deposit-release"><b>Back to the renter: {$(release)}</b>{!pv.may_release_without_approval && release > 0 ? ' (an amount above your limit goes to an Admin to approve)' : ''}</p>
          {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
          {done && <p className="alert alert--ok" role="status"><span>{done}</span></p>}
          <div className="row">
            <button className="btn btn--primary btn--sm" type="submit" disabled={pending || !pv.has_statement || !!done} data-testid="deposit-submit">{pending ? 'Working' : 'Settle'}</button>
            <button className="btn btn--ghost btn--sm" type="button" onClick={() => dlg.current?.close()}>Close</button>
          </div>
        </form>}
        {!pv && err && <><p className="alert alert--error" role="alert"><span>{err}</span></p><button className="btn btn--ghost btn--sm" type="button" onClick={() => dlg.current?.close()}>Close</button></>}
      </dialog>
    </>
  );
}
