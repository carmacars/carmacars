'use client';
import { useRouter } from 'next/navigation';
import { useState } from 'react';
import { DateInput } from '@/components/DateInput';
import { hireApplicant, hirePreview, sendHireAgreementNow, verifyStaffPay, type HirePreview } from '@/server/actions/hiring';
import { HIRE_FUNCTION_LABEL, STEP_WORDS, payCents, type HireFunction, type HireStatus } from '@/features/careers/hire';

// One-step Hire (release 33, migration 0730): one short form (the role, the start date, the pay as the role's standard,
// editable) and one confirm. Then the status card shows each onboarding step done or waiting.
export function Hire({ id, name, status }: { id: string; name: string; status: HireStatus | null }) {
  const router = useRouter();
  const [mine, setSt] = useState<HireStatus | null>(null);
  // the server's card once the page refreshed; the one this confirm returned until then
  const st = status?.onboarding ? status : mine;
  const [pv, setPv] = useState<HirePreview | null>(null);
  const [fn, setFn] = useState<string>('');
  const [start, setStart] = useState('');
  const [pay, setPay] = useState('');
  const [cur, setCur] = useState('USD');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const load = async (f?: string) => {
    setBusy(true); setErr(null);
    const r = await hirePreview(id, f ?? null);
    setBusy(false);
    if (!r.ok) { setErr(r.message); return; }
    setPv(r.data); setFn(r.data.function); setStart((s) => s || r.data.start_on);
    const p = r.data.standard_pay[r.data.function] ?? r.data.pay;
    setPay(p.cents ? (p.cents / 100).toFixed(2) : ''); setCur(p.currency ?? 'USD');
  };
  const choose = (f: string) => {
    setFn(f);
    const p = pv?.standard_pay[f];
    if (p) { setPay(p.cents ? (p.cents / 100).toFixed(2) : ''); setCur(p.currency ?? 'USD'); }
  };
  const std = pv ? pv.standard_pay[fn] : null;
  const commission = std?.basis === 'commission';
  async function confirm(e: React.FormEvent) {
    e.preventDefault();
    const cents = commission ? null : payCents(pay);
    if (!commission && !cents) { setErr('Enter the pay.'); return; }
    if (!start) { setErr('Choose the start date.'); return; }
    setBusy(true); setErr(null);
    const r = await hireApplicant({ id, function: fn, start_on: start, pay_cents: cents, pay_currency: commission ? null : cur });
    setBusy(false);
    if (!r.ok) { setErr(r.message); return; }
    setSt(r.data); setPv(null); router.refresh();
  }

  if (st) return <HireStatusCard id={id} status={st} onChange={(s) => { setSt(s); router.refresh(); }} />;
  if (!pv) return (
    <span className="stack">
      <button type="button" className="btn btn--primary" onClick={() => load()} disabled={busy} data-testid="hire">{busy ? 'Opening' : `Hire ${name}`}</button>
      {err && <span className="error" role="alert">{err}</span>}
    </span>
  );
  return (
    <form className="stack" noValidate onSubmit={confirm} aria-label={`Hire ${name}`} data-testid="hire-form">
      <div className="field"><label className="label" htmlFor={`hire-fn-${id}`}>Role</label>
        <select className="select" id={`hire-fn-${id}`} value={fn} onChange={(e) => choose(e.target.value)} data-testid="hire-function">
          {pv.functions.map((f) => <option key={f.code} value={f.code}>{HIRE_FUNCTION_LABEL[f.code as HireFunction] ?? f.label}</option>)}
        </select>
        {pv.outside_area && <p className="hint" data-testid="hire-outside">They live outside the Toronto area: Sales is remote (in person needs the area).</p>}</div>
      <div className="field"><label className="label" htmlFor={`hire-start-${id}`}>Start date</label>
        <DateInput className="input" type="date" id={`hire-start-${id}`} value={start} onChange={(e) => setStart(e.target.value)} data-testid="hire-start" /></div>
      {commission
        ? <p className="small" data-testid="hire-pay-commission"><b>Pay:</b> {std?.text}</p>
        : <div className="field"><label className="label" htmlFor={`hire-pay-${id}`}>Pay ({cur} {std?.basis === 'hourly' ? 'an hour' : 'a month'}; the role&apos;s standard is {std?.text})</label>
            <input className="input" inputMode="decimal" id={`hire-pay-${id}`} value={pay} onChange={(e) => setPay(e.target.value)} data-testid="hire-pay" /></div>}
      <div className="small"><b>One confirm does all of this:</b>
        <ol className="cr-guide">{pv.will_do.map((w) => <li key={w}>{w}</li>)}</ol></div>
      <p className="row">
        <button type="submit" className="btn btn--primary" disabled={busy} data-testid="hire-confirm">{busy ? 'Hiring' : 'Confirm: hire and start onboarding'}</button>
        <button type="button" className="btn btn--ghost" onClick={() => setPv(null)} disabled={busy}>Cancel</button>
      </p>
      {err && <p className="error" role="alert">{err}</p>}
    </form>
  );
}

/** Each onboarding step, done or waiting, with the two things an Admin may still do: send the agreement once its values are
 *  in, and verify the pay details the hire entered. */
export function HireStatusCard({ id, status, onChange }: { id: string; status: HireStatus; onChange?: (s: HireStatus) => void }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [how, setHow] = useState('');
  const steps = status.steps ?? [];
  const again = async () => {
    setBusy(true); setErr(null);
    const r = await sendHireAgreementNow(id);
    setBusy(false);
    if (!r.ok) { setErr(r.message); return; }
    onChange?.(r.data); router.refresh();
  };
  const verify = async (payoutId: string) => {
    setBusy(true); setErr(null);
    const r = await verifyStaffPay(id, payoutId, how);
    setBusy(false);
    if (!r.ok) { setErr(r.message); return; }
    router.refresh();
  };
  return (
    <div className="stack" data-testid="hire-status">
      <p className="small"><b>{status.name}</b>, {status.function_label}, from {status.start_on}. Pay: {status.pay}.</p>
      <ul className="stack" style={{ listStyle: 'none', padding: 0 }}>
        {steps.map((s) => (
          <li key={s.key} className="stack" data-testid={`hire-step-${s.key}`} data-state={s.state}>
            <span><span className="ad-b" data-status={s.state}>{STEP_WORDS[s.state]}</span> <b>{s.label}</b></span>
            <span className="small muted">{s.detail}</span>
            {s.key === 'agreement' && s.state === 'todo' && <button type="button" className="btn btn--ghost btn--sm" onClick={again} disabled={busy} data-testid="hire-send-agreement">Send the agreement</button>}
            {s.key === 'pay' && s.verify && s.payout_id && <span className="row">
              <input className="input" aria-label="How you checked them" placeholder="How you checked them, for example a video call" value={how} onChange={(e) => setHow(e.target.value)} data-testid="hire-verify-how" />
              <button type="button" className="btn btn--ghost btn--sm" onClick={() => verify(s.payout_id!)} disabled={busy} data-testid="hire-verify">Verify</button></span>}
          </li>
        ))}
      </ul>
      {err && <p className="error" role="alert">{err}</p>}
    </div>
  );
}
