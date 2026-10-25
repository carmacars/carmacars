'use client';
import { useId, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { opsRead } from '@/server/actions/ops';
import { addDamageCharge, keepWholeDeposit, settleDeposit, type SettleResult } from '@/server/actions/deposit';
import { chargeSavedCard } from '@/server/actions/offers';
import { depositMethod, depositStatus } from '@/features/money/deposit-words';

// The guided Deposit settlement (migration 0020's app.settle_deposit, guarded by 0155): what is owed is taken from the
// deposit first; tolls and tickets can take days to come in, so a settlement inside that window holds the deposit back
// unless the person chooses to release now; anything still open (an incident, a claim, damage not priced, a toll on the
// car not matched, a card dispute) keeps the whole deposit unless an Admin gives the reason. An Admin keeps the whole
// deposit for damage in one step, or bills a damage charge. The form shows the arithmetic before anything moves; the
// database decides.
interface Guard {
  available_cents: number; due_cents: number; remaining_cents: number; toll_window_days: number; toll_window_ends_on: string | null; within_window: boolean;
  blockers: Array<{ kind: string; label: string }>; blocked: boolean; suggested_hold_back_cents: number; suggested_hold_back_until: string | null;
  hold_expires_at: string | null; card_on_file: boolean; deposit_to_charge: boolean; deposit_cents: number; balance_open_cents: number; is_admin: boolean;
}
interface Preview {
  booking_number: string; status: string; has_statement: boolean; available_cents: number; due_cents: number; apply_cents: number; shortfall_cents: number;
  hold_back_max_cents: number; hold_back_until_max: string | null; holdback_days: number; may_release_without_approval: boolean; deductible_cents: number;
  deposit: { status: string; method: string; amount_cents: number; applied_cents: number; held_back_cents: number; held_back_reason: string | null; held_back_until: string | null; released_cents: number } | null;
  guard: Guard;
}
const $ = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const day = (d: string | null) => (d ? new Date(`${d}T12:00:00`).toLocaleDateString('en-CA', { month: 'long', day: 'numeric' }) : '');
const REASONS: Array<[string, string]> = [['pending_toll', 'Tolls or tickets may still come in'], ['pending_claim', 'A damage claim is pending'], ['pending_ticket', 'A ticket or fine is expected'], ['other', 'Something else']];
const cents = (s: string) => Math.max(0, Math.round(Number(s.replace(/[$,\s]/g, '')) * 100) || 0);

export function DepositSettle({ bookingId, bookingNumber, refresh = [] }: { bookingId: string; bookingNumber?: string; refresh?: string[] }) {
  const id = useId().replace(/:/g, '');
  const dlg = useRef<HTMLDialogElement>(null);
  const router = useRouter();
  const [pv, setPv] = useState<Preview | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [hold, setHold] = useState('0.00');
  const [why, setWhy] = useState('pending_toll');
  const [detail, setDetail] = useState('');
  const [until, setUntil] = useState('');
  const [releaseNow, setReleaseNow] = useState(false);
  const [override, setOverride] = useState('');
  const [panel, setPanel] = useState<'' | 'keep' | 'damage'>('');
  const [dmg, setDmg] = useState({ amount: '', reason: '', photos: '' });
  const [done, setDone] = useState<string | null>(null);
  const [pending, start] = useTransition();

  const load = async () => {
    const r = await opsRead<Preview>('deposit_preview', { booking: bookingId });
    if (!r.ok) { setErr(r.message); return null; }
    const g = r.data.guard;
    setPv(r.data);
    // anything still open, or inside the toll window: the whole deposit is held back by default
    const held = r.data.deposit?.held_back_cents ?? 0;
    const pre = g.blocked || g.within_window ? Math.max(g.suggested_hold_back_cents, held) : held;
    setHold((Math.min(pre, r.data.hold_back_max_cents) / 100).toFixed(2));
    setWhy(g.blocked ? (g.blockers.some((b) => b.kind === 'toll') ? 'pending_toll' : 'pending_claim') : 'pending_toll');
    setDetail(r.data.deposit?.held_back_reason ?? (g.blocked ? g.blockers.map((b) => b.label).join('; ') : g.within_window ? `Tolls and tickets until ${day(g.toll_window_ends_on)}` : ''));
    setUntil(r.data.deposit?.held_back_until ?? (g.blocked ? g.suggested_hold_back_until : g.toll_window_ends_on) ?? r.data.hold_back_until_max ?? '');
    setReleaseNow(false); setOverride('');
    return r.data;
  };
  const open = () => start(async () => { setErr(null); setDone(null); setPanel(''); await load(); dlg.current?.showModal(); });

  const g = pv?.guard;
  const holdCents = cents(hold);
  const tooMuch = pv ? holdCents > pv.hold_back_max_cents : false;
  const release = pv ? Math.max(0, pv.available_cents - pv.apply_cents - holdCents) : 0;
  const needsOverride = !!g && g.blocked && release > 0;
  const needsNow = !!g && !g.blocked && g.within_window && release > 0;

  const words = (r: SettleResult) => {
    if (r.status === 'awaiting_approval') return 'Sent to an Admin to approve the release.';
    const parts = [`${$(r.released_cents)} back to the renter`];
    if (r.applied_cents > 0) parts.unshift(`${$(r.applied_cents)} taken from the deposit for the charges`);
    if (r.held_back_cents > 0) parts.push(`${$(r.held_back_cents)} held back${until ? ` until ${day(until)}` : ''}`);
    if (r.charged_to_card_cents > 0) parts.push(`${$(r.charged_to_card_cents)} charged to the card on file`);
    const failed = r.money.filter((m) => !m.ok);
    const bal = r.balance && r.balance.open_cents > 0 ? ` ${$(r.balance.open_cents)} is still owed: ${r.balance.action === 'pay_link' ? 'a pay link went to the renter by email and text' : r.balance.action === 'charge_card' ? 'the card on file is being charged' : 'Finance has a task to collect it'}.` : '';
    return `Settled: ${parts.join(', ')}.${bal}${failed.length ? ' Stripe did not take one step yet: it is tried again by itself, and Finance gets a task if it keeps failing.' : ''}`;
  };

  const submit = () => start(async () => {
    setErr(null);
    if (!pv || !g) return;
    if (tooMuch) { setErr(`At most ${$(pv.hold_back_max_cents)} can be held back.`); return; }
    if (holdCents > 0 && !detail.trim()) { setErr('Say what the hold-back is for (the toll, ticket or claim).'); return; }
    if (needsOverride && (!g.is_admin || override.trim().length < 10)) { setErr(g.is_admin ? 'Give the reason for releasing part of the deposit (10 characters or more).' : 'The whole deposit stays held while something is still open. An Admin can release part of it with the reason.'); return; }
    if (needsNow && !releaseNow) { setErr(`Tolls and tickets can take up to ${g.toll_window_days} days to come in. Hold back an amount until ${day(g.toll_window_ends_on)}, or choose Release now anyway.`); return; }
    const reason = holdCents > 0 ? `${REASONS.find((x) => x[0] === why)?.[1] ?? why}: ${detail.trim()}` : null;
    const r = await settleDeposit({ booking: bookingId, hold_back_cents: holdCents, hold_back_reason: reason, hold_back_until: holdCents > 0 ? until || null : null,
      release_now: needsNow ? releaseNow : undefined, override_reason: needsOverride ? override.trim() : undefined }, refresh);
    if (!r.ok) { setErr(r.message); return; }
    setDone(words(r.data));
    router.refresh();
  });

  const keepWhole = () => start(async () => {
    setErr(null);
    if (dmg.reason.trim().length < 10) { setErr('Say what was damaged (10 characters or more): the renter sees it.'); return; }
    const photos = dmg.photos.split(/\n|,/).map((x) => x.trim()).filter(Boolean);
    if (!photos.length) { setErr('Name the damage photos (the condition report photos or the files).'); return; }
    const r = panel === 'keep'
      ? await keepWholeDeposit({ booking: bookingId, reason: dmg.reason.trim(), photos }, refresh)
      : await addDamageCharge({ booking: bookingId, amount_cents: cents(dmg.amount), reason: dmg.reason.trim(), photos }, refresh);
    if (!r.ok) { setErr(r.message); return; }
    setDone(panel === 'keep' ? `The whole deposit${r.data.kept_cents ? ` (${$(r.data.kept_cents)})` : ''} is kept for the damage. The renter is told.` : 'The damage charge is on the booking. The renter is told.');
    setPanel('');
    await load();
    router.refresh();
  });

  const chargeDeposit = () => start(async () => {
    setErr(null);
    if (!g) return;
    const r = await chargeSavedCard({ booking: bookingNumber ?? bookingId, reason: 'The deposit, charged at the return', covers: 'deposit' });
    if (!r.ok) { setErr(r.message); return; }
    if (!r.data.ok) { setErr(r.data.message ?? 'The card was declined.'); return; }
    await load();
    router.refresh();
  });

  return (
    <>
      <button className="btn btn--ghost btn--sm" type="button" onClick={open} disabled={pending} data-testid="deposit-settle">Settle the deposit</button>
      <dialog ref={dlg} className="ad-dialog" aria-labelledby={`${id}-t`}>
        <h2 className="d4" id={`${id}-t`}>Settle the deposit</h2>
        {pv && g && <form className="ad-form" noValidate onSubmit={(e) => { e.preventDefault(); submit(); }} data-testid="deposit-form">
          <dl className="pt-dl ad-kv">
            <div><dt>Deposit</dt><dd>{pv.deposit ? `${$(pv.deposit.amount_cents)}, ${depositMethod(pv.deposit.method).toLowerCase()}, ${depositStatus(pv.deposit.status).toLowerCase()}` : 'None taken'}</dd></div>
            <div><dt>Still available</dt><dd>{$(pv.available_cents)}</dd></div>
            <div><dt>Charges owed from the statement</dt><dd>{$(pv.due_cents)}</dd></div>
            <div><dt>Taken from the deposit for them</dt><dd>{$(pv.apply_cents)}</dd></div>
            {pv.shortfall_cents > 0 && <div><dt>{g.card_on_file ? 'Charged to the card on file' : 'Still owed (a pay link goes to the renter)'}</dt><dd>{$(pv.shortfall_cents)}</dd></div>}
          </dl>
          {!pv.has_statement && <p className="alert alert--error" role="alert"><span>Issue the Check-in statement first (Overview, Issue final statement).</span></p>}
          {g.deposit_to_charge && g.card_on_file && pv.has_statement && <div className="alert alert--info" data-testid="deposit-charge-first"><span>No deposit was taken (a long rental saves the card instead). Charge the deposit of {$(g.deposit_cents)} to the saved card first, so it covers what comes in later.</span>
            <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={chargeDeposit} data-testid="deposit-charge-go">Charge the deposit to the saved card</button></div>}
          {g.blocked && <div className="alert alert--warn" data-testid="deposit-blockers"><span><b>Keep the whole deposit: something can still be owed.</b></span>
            <ul className="small">{g.blockers.map((b, i) => <li key={i}>{b.label}</li>)}</ul></div>}
          {!g.blocked && g.within_window && <p className="alert alert--info" data-testid="deposit-window"><span>The car came back less than {g.toll_window_days} days ago. Tolls and tickets can take up to {g.toll_window_days} days to come in, so the deposit is held back until {day(g.toll_window_ends_on)}.</span></p>}
          <div className="ad-fields">
            <div className={`field ad-field${tooMuch ? ' has-error' : ''}`}><label className="label" htmlFor={`${id}-h`}>Hold back ($)</label>
              <input className="input" id={`${id}-h`} inputMode="decimal" value={hold} onChange={(e) => setHold(e.target.value)} aria-describedby={`${id}-hh`} data-testid="deposit-hold" />
              <p className="hint" id={`${id}-hh`}>Up to {$(pv.hold_back_max_cents)}, for at most {pv.holdback_days} days after the return.</p></div>
            {holdCents > 0 && <>
              <div className="field ad-field"><label className="label" htmlFor={`${id}-r`}>Why</label>
                <select className="select" id={`${id}-r`} value={why} onChange={(e) => setWhy(e.target.value)}>{REASONS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></div>
              <div className="field ad-field ad-field--wide"><label className="label" htmlFor={`${id}-d`}>What it is (claim, toll or ticket)</label>
                <input className="input" id={`${id}-d`} value={detail} onChange={(e) => setDetail(e.target.value)} placeholder="Rear bumper scuff, estimate requested" /></div>
              <div className="field ad-field"><label className="label" htmlFor={`${id}-u`}>Hold until</label>
                <input className="input" id={`${id}-u`} type="date" value={until} max={pv.hold_back_until_max ?? undefined} onChange={(e) => setUntil(e.target.value)} /></div>
            </>}
          </div>
          {needsNow && <label className="check" data-testid="deposit-release-now"><input type="checkbox" checked={releaseNow} onChange={(e) => setReleaseNow(e.target.checked)} /> <span>Release now anyway (a toll or ticket that comes in later is charged to the card on file)</span></label>}
          {needsOverride && g.is_admin && <div className="field ad-field ad-field--wide"><label className="label" htmlFor={`${id}-o`}>Release part of it anyway: the reason (Admin, recorded)</label>
            <input className="input" id={`${id}-o`} value={override} onChange={(e) => setOverride(e.target.value)} data-testid="deposit-override" /></div>}
          <p className="ad-tie" data-testid="deposit-release"><b>Back to the renter: {$(release)}</b>{!pv.may_release_without_approval && release > 0 ? ' (an amount above your limit goes to an Admin to approve)' : ''}</p>
          {err && <p className="alert alert--error" role="alert" data-testid="deposit-error"><span>{err}</span></p>}
          {done && <p className="alert alert--ok" role="status" data-testid="deposit-done"><span>{done}</span></p>}
          <div className="row">
            <button className="btn btn--primary btn--sm" type="submit" disabled={pending || !pv.has_statement || !!done} data-testid="deposit-submit">{pending ? 'Working' : 'Settle'}</button>
            {g.is_admin && pv.has_statement && g.remaining_cents > 0 && <button className="btn btn--ghost btn--sm" type="button" aria-expanded={panel === 'keep'} onClick={() => setPanel(panel === 'keep' ? '' : 'keep')} data-testid="deposit-keep">Keep the whole deposit (damage)</button>}
            {g.is_admin && <button className="btn btn--ghost btn--sm" type="button" aria-expanded={panel === 'damage'} onClick={() => setPanel(panel === 'damage' ? '' : 'damage')} data-testid="deposit-damage">Bill damage</button>}
            <button className="btn btn--ghost btn--sm" type="button" onClick={() => dlg.current?.close()}>Close</button>
          </div>
          {panel && <fieldset className="ad-form" data-testid="deposit-damage-form">
            <legend className="small"><b>{panel === 'keep' ? `Keep the whole deposit: ${$(g.remaining_cents)} becomes a damage charge` : `A damage charge (up to ${$(pv.deductible_cents)}; more goes through a claim)`}</b></legend>
            <div className="ad-fields">
              {panel === 'damage' && <div className="field ad-field"><label className="label" htmlFor={`${id}-da`}>Amount ($)</label><input className="input" id={`${id}-da`} inputMode="decimal" value={dmg.amount} onChange={(e) => setDmg({ ...dmg, amount: e.target.value })} data-testid="damage-amount" /></div>}
              <div className="field ad-field ad-field--wide"><label className="label" htmlFor={`${id}-dr`}>What was damaged (the renter sees it)</label><input className="input" id={`${id}-dr`} value={dmg.reason} onChange={(e) => setDmg({ ...dmg, reason: e.target.value })} data-testid="damage-reason" /></div>
              <div className="field ad-field ad-field--wide"><label className="label" htmlFor={`${id}-dp`}>Photos (the condition report photo numbers or file names, one per line)</label><textarea className="input" id={`${id}-dp`} rows={2} value={dmg.photos} onChange={(e) => setDmg({ ...dmg, photos: e.target.value })} data-testid="damage-photos" /></div>
            </div>
            <button className="btn btn--primary btn--sm" type="button" disabled={pending} onClick={keepWhole} data-testid="damage-go">{panel === 'keep' ? 'Keep the whole deposit' : 'Bill the damage'}</button>
          </fieldset>}
        </form>}
        {!pv && err && <><p className="alert alert--error" role="alert"><span>{err}</span></p><button className="btn btn--ghost btn--sm" type="button" onClick={() => dlg.current?.close()}>Close</button></>}
      </dialog>
    </>
  );
}
