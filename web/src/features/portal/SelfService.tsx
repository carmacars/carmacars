'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { cancelBooking, payExtension, previewChange, previewExtension, requestChange, requestExtension, withdrawChange, agreeChange } from '@/server/actions/portal';
import { clock, timeSlots, torontoInstant } from '@/lib/dates';
import { money } from '@/lib/format';
import { when } from '@/features/agreement/model';
import { useAct } from './useAct';

// Cancel (type to confirm), extend (preview, request, pay once approved) and change dates (preview,
// request). Every number shown comes from the database's preview functions.
export function CancelForm({ number }: { number: string }) {
  const [typed, setTyped] = useState('');
  const a = useAct<{ refundCents: number | null }>();
  if (a.res?.ok) return <div className="pt-ok" role="status"><h2 className="d4">Booking cancelled</h2><p>We have your cancellation. Any refund is sent to your card within 10 business days.</p><p><a className="btn btn--primary" href={`/account/bookings/${encodeURIComponent(number)}`}>Back to the booking</a></p></div>;
  return (
    <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => cancelBooking(number, typed)); }}>
      <div className={`field${a.err('confirm') ? ' has-error' : ''}`}>
        <label className="label" htmlFor="pt-cancel-confirm">Type <b>{number}</b> to confirm</label>
        <input className="input" id="pt-cancel-confirm" value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" autoCapitalize="characters" spellCheck={false} aria-invalid={!!a.err('confirm') || undefined} aria-describedby="pt-cancel-err" />
        <p className="error" role="alert" id="pt-cancel-err">{a.err('confirm') ?? (a.res && !a.res.ok ? a.res.message : '')}</p>
      </div>
      <button className="btn btn--primary" type="submit" disabled={a.pending}>{a.pending ? 'Cancelling' : 'Cancel booking'}</button>
    </form>
  );
}

function DateTime({ id, label, date, time, onDate, onTime, min }: { id: string; label: string; date: string; time: string; onDate: (v: string) => void; onTime: (v: string) => void; min?: string }) {
  return (
    <fieldset className="field-row" style={{ border: 0, padding: 0, margin: 0 }}>
      <legend className="label" style={{ marginBottom: 'var(--s-2)' }}>{label}</legend>
      <div className="field"><label className="label small" htmlFor={`${id}-d`}>Date</label><input className="input" type="date" id={`${id}-d`} value={date} min={min} onChange={(e) => onDate(e.target.value)} /></div>
      <div className="field"><label className="label small" htmlFor={`${id}-t`}>Time</label>
        <select className="select" id={`${id}-t`} value={time} onChange={(e) => onTime(e.target.value)}>{timeSlots().map((t) => <option key={t} value={t}>{clock(t)}</option>)}</select></div>
    </fieldset>
  );
}

interface Line { label?: string; description?: string; amount_cents: number }
function Lines({ lines, hst, total, totalLabel }: { lines: Line[]; hst: number; total: number; totalLabel: string }) {
  return (
    <dl className="pt-dl pt-dl--money" data-testid="preview-lines">
      {lines.map((l, i) => <div key={i}><dt>{l.description ?? l.label}</dt><dd>{money(l.amount_cents, { cents: true })}</dd></div>)}
      <div><dt>HST</dt><dd>{money(hst, { cents: true })}</dd></div>
      <div><dt><b>{totalLabel}</b></dt><dd className="pt-total" data-testid="preview-total">{money(total, { cents: true })}</dd></div>
    </dl>
  );
}

export function ExtendForm({ number, returnDate, returnTime, approved }: { number: string; returnDate: string; returnTime: string; approved: { id: string; total_cents: number; new_return_at: string } | null }) {
  const router = useRouter();
  const [date, setDate] = useState(returnDate);
  const [time, setTime] = useState(returnTime);
  const [note, setNote] = useState('');
  const prev = useAct<Record<string, unknown>>();
  const req = useAct();
  const pay = useAct();
  const p = prev.res?.ok ? (prev.res.data as { ok?: boolean; total_cents: number; hst_cents: number; lines: Line[]; new_days: number; problems?: { message: string }[]; available?: boolean; message?: string }) : null;
  if (approved) return (
    <div className="stack">
      <p>Your extension to <b>{when(approved.new_return_at)}</b> is approved. Pay {money(approved.total_cents, { cents: true })} with your Card on File to confirm it before your current return time.</p>
      {pay.res && !pay.res.ok && <p className="alert alert--error" role="alert"><span>{pay.res.message}</span></p>}
      {pay.res?.ok ? <p className="alert alert--ok" role="status"><span>Paid. Your new return time is confirmed.</span></p>
        : <button className="btn btn--primary" type="button" disabled={pay.pending} onClick={() => pay.run(() => payExtension(number, approved.id), (r) => { if (r.ok) router.refresh(); })}>{pay.pending ? 'Paying' : `Pay ${money(approved.total_cents, { cents: true })}`}</button>}
    </div>
  );
  if (req.res?.ok) return <p className="alert alert--ok" role="status"><span className="alert__title">Extension requested</span><span>We will confirm it shortly. Once approved, you pay here before your current return time.</span></p>;
  return (
    <div className="stack-lg">
      <DateTime id="pt-ext" label="New return date and time" date={date} time={time} onDate={setDate} onTime={setTime} min={returnDate} />
      <button className="btn btn--ghost" type="button" disabled={prev.pending} onClick={() => prev.run(() => previewExtension(number, torontoInstant(date, time)))}>{prev.pending ? 'Pricing' : 'See the price'}</button>
      {prev.res && !prev.res.ok && <p className="alert alert--error" role="alert"><span>{prev.res.message}</span></p>}
      {p && (p.ok === false || p.problems?.length) ? <p className="alert alert--warn" role="alert"><span>{p.message ?? p.problems?.map((x) => x.message).join(' ')}</span></p> : null}
      {p && p.ok !== false && <>
        <Lines lines={p.lines ?? []} hst={p.hst_cents} total={p.total_cents} totalLabel={`To pay for ${p.new_days} days in total`} />
        <div className="field"><label className="label" htmlFor="pt-ext-note">Note (optional)</label><textarea className="textarea" id="pt-ext-note" maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} /></div>
        {req.res && !req.res.ok && <p className="alert alert--error" role="alert"><span>{req.res.message}</span></p>}
        <button className="btn btn--primary" type="button" disabled={req.pending} onClick={() => req.run(() => requestExtension(number, torontoInstant(date, time), note), (r) => { if (r.ok) router.refresh(); })}>{req.pending ? 'Sending' : 'Request extension'}</button>
      </>}
    </div>
  );
}

export function ChangeForm({ number, pickupDate, pickupTime, returnDate, returnTime }: { number: string; pickupDate: string; pickupTime: string; returnDate: string; returnTime: string }) {
  const router = useRouter();
  const [v, setV] = useState({ pd: pickupDate, pt: pickupTime, rd: returnDate, rt: returnTime });
  const [note, setNote] = useState('');
  const prev = useAct<Record<string, unknown>>();
  const req = useAct();
  const changes = () => ({ pickup_at: torontoInstant(v.pd, v.pt), return_at: torontoInstant(v.rd, v.rt) });
  const p = prev.res?.ok ? (prev.res.data as { ok?: boolean; total_difference_cents: number; hst_cents: number; difference_cents: number; lines: Line[]; problems?: { message: string }[]; message?: string; after?: { total_cents: number } }) : null;
  if (req.res?.ok) return <p className="alert alert--ok" role="status"><span className="alert__title">Change requested</span><span>We will price it and reply. Nothing changes until you agree.</span></p>;
  return (
    <div className="stack-lg">
      <DateTime id="pt-chg-p" label="New pickup" date={v.pd} time={v.pt} onDate={(x) => setV({ ...v, pd: x })} onTime={(x) => setV({ ...v, pt: x })} />
      <DateTime id="pt-chg-r" label="New return" date={v.rd} time={v.rt} onDate={(x) => setV({ ...v, rd: x })} onTime={(x) => setV({ ...v, rt: x })} />
      <button className="btn btn--ghost" type="button" disabled={prev.pending} onClick={() => prev.run(() => previewChange(number, changes()))}>{prev.pending ? 'Pricing' : 'See the difference'}</button>
      {prev.res && !prev.res.ok && <p className="alert alert--error" role="alert"><span>{prev.res.message}</span></p>}
      {p && (p.ok === false || p.problems?.length) ? <p className="alert alert--warn" role="alert"><span>{p.message ?? p.problems?.map((x) => x.message).join(' ')}</span></p> : null}
      {p && p.ok !== false && <>
        <dl className="pt-dl pt-dl--money"><div><dt>New total</dt><dd>{money(p.after?.total_cents ?? 0, { cents: true })}</dd></div><div><dt><b>{p.total_difference_cents >= 0 ? 'You would pay' : 'You would get back'}</b></dt><dd className="pt-total">{money(Math.abs(p.total_difference_cents), { cents: true })}</dd></div></dl>
        <div className="field"><label className="label" htmlFor="pt-chg-note">Note (optional)</label><textarea className="textarea" id="pt-chg-note" maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} /></div>
        {req.res && !req.res.ok && <p className="alert alert--error" role="alert"><span>{req.res.message}</span></p>}
        <button className="btn btn--primary" type="button" disabled={req.pending} onClick={() => req.run(() => requestChange(number, changes(), note), (r) => { if (r.ok) router.refresh(); })}>{req.pending ? 'Sending' : 'Ask to change dates'}</button>
      </>}
    </div>
  );
}

export function ChangeRequestActions({ number, id, status }: { number: string; id: string; status: string }) {
  const router = useRouter();
  const a = useAct();
  const done = (r: { ok: boolean }) => { if (r.ok) router.refresh(); };
  return (
    <div className="row">
      {status === 'proposed' || status === 'approved' ? <button className="btn btn--primary btn--sm" type="button" disabled={a.pending} onClick={() => a.run(() => agreeChange(number, id), done)}>Agree to the change</button> : null}
      {['requested', 'proposed', 'approved'].includes(status) && <button className="btn btn--quiet btn--sm" type="button" disabled={a.pending} onClick={() => a.run(() => withdrawChange(number, id), done)}>Withdraw</button>}
      {a.res && !a.res.ok && <p className="error" role="alert">{a.res.message}</p>}
    </div>
  );
}
