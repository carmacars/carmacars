'use client';
import { useId, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { opsAct } from '@/server/actions/ops';
import { signOut } from '@/server/actions/auth';
import { DateInput } from '@/components/DateInput';
import { dayWords, endsNow, lastDayProblem, nextSteps, type ResignFacts } from './resign';

type Step = 'idle' | 'form' | 'confirm' | 'done' | 'withdraw';
type Sent = { status: string; last_day: string; ended: boolean };

// r50 (5020): Resign, on My profile (and on Welcome while in onboarding). A form (last day, optional reason), then a
// confirm step that says what happens next, then the confirmation. Pending: the last day and Withdraw my resignation.
// Every step is a full-size button (48px); the text wraps, nothing is squeezed at 320px.
export function ResignForm({ facts, refresh, testId = 'resign' }: { facts: ResignFacts; refresh: string[]; testId?: string }) {
  const router = useRouter();
  const idp = useId().replace(/:/g, '');
  const [step, setStep] = useState<Step>('idle');
  const [day, setDay] = useState(facts.default_last_day ?? '');
  const [reason, setReason] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [sent, setSent] = useState<Sent | null>(null);
  const [pending, start] = useTransition();
  const r = facts.resignation;

  if (step === 'done' && sent) {
    return (
      <div className="stack" data-testid={`${testId}-done`} role="status">
        <p className="alert alert--ok"><span><b>Your resignation is in.</b> Last day: {dayWords(sent.last_day)}. We emailed you a confirmation, and the Admins and Finance are told.</span></p>
        {sent.ended
          ? <><p className="small">Your access has ended. Thank you for your time with CarmaCars.</p>
              <form action={signOut}><button className="btn btn--primary" type="submit" data-testid={`${testId}-signout`}>Sign out</button></form></>
          : <button className="btn btn--ghost" type="button" onClick={() => { setStep('idle'); router.refresh(); }} data-testid={`${testId}-close`}>Back to my profile</button>}
      </div>
    );
  }

  // a pending resignation: its last day, and Withdraw until then
  if (r && r.status === 'pending') {
    return (
      <div className="stack" data-testid={`${testId}-pending`}>
        <p className="alert alert--warn"><span><b>You resigned on {dayWords(r.resigned_on)}.</b> Your last day is {dayWords(r.last_day)}; your access ends after it.{r.by_self ? '' : ' An Admin recorded it.'}</span></p>
        {facts.words && <p className="small">{facts.words.final_pay_text}</p>}
        {r.can_withdraw && (step === 'withdraw'
          ? <div className="stack">
              <p className="small">Withdraw your resignation? You stay on the team. Shifts and jobs after your old last day stay with the team: ask Fleet for them again.</p>
              {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
              <div className="row">
                <button className="btn btn--primary" type="button" disabled={pending} data-testid={`${testId}-withdraw-confirm`}
                  onClick={() => start(async () => { setErr(null); const x = await opsAct('staff_resign_withdraw', {}, refresh); if (!x.ok) { setErr(x.message); return; } setStep('idle'); router.refresh(); })}>
                  {pending ? 'Working' : 'Yes, withdraw it'}</button>
                <button className="btn btn--ghost" type="button" onClick={() => setStep('idle')}>Keep my resignation</button>
              </div>
            </div>
          : <div><button className="btn btn--ghost" type="button" onClick={() => { setErr(null); setStep('withdraw'); }} data-testid={`${testId}-withdraw`}>Withdraw my resignation</button></div>)}
      </div>
    );
  }

  if (step === 'idle') {
    return (
      <div className="stack">
        <p className="small">Leaving CarmaCars? Give your notice here: {facts.notice_days} days, as your agreement says{facts.can_today ? ' (while you are still in onboarding or your trial period you may leave today)' : ''}. You can withdraw it until your last day.</p>
        <div><button className="btn btn--ghost" type="button" onClick={() => { setErr(null); setStep('form'); }} data-testid={`${testId}-open`}>Resign</button></div>
      </div>
    );
  }

  if (step === 'form') {
    const next = () => { const p = lastDayProblem(facts, day); setErr(p); if (!p) setStep('confirm'); };
    return (
      <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); next(); }} data-testid={`${testId}-form`}>
        <div className={`field${err ? ' has-error' : ''}`}>
          <label className="label" htmlFor={`${idp}-day`}>My last day</label>
          <DateInput className="input" id={`${idp}-day`} type="date" value={day} min={facts.earliest} max={facts.latest} required aria-describedby={`${idp}-day-hint${err ? ` ${idp}-day-err` : ''}`}
            onChange={(e) => setDay(e.target.value)} data-testid={`${testId}-day`} />
          <p className="hint" id={`${idp}-day-hint`}>{facts.notice_days} days from today is {dayWords(facts.default_last_day)}.{facts.can_today ? ' Today is allowed: your access then ends at once.' : ''}</p>
          {err && <p className="error" role="alert" id={`${idp}-day-err`}>{err}</p>}
        </div>
        <div className="field">
          <label className="label" htmlFor={`${idp}-why`}>Reason (optional)</label>
          <textarea className="textarea" id={`${idp}-why`} value={reason} maxLength={1000} onChange={(e) => setReason(e.target.value)} data-testid={`${testId}-reason`} />
          <p className="hint">Only the Admins see it.</p>
        </div>
        <div className="row">
          <button className="btn btn--primary" type="submit" data-testid={`${testId}-continue`}>Continue</button>
          <button className="btn btn--ghost" type="button" onClick={() => setStep('idle')}>Cancel</button>
        </div>
      </form>
    );
  }

  // confirm: what happens next
  return (
    <div className="stack" data-testid={`${testId}-confirm`}>
      <p><b>Before you confirm, here is what happens next:</b></p>
      <ul className="stack" data-testid={`${testId}-next`}>{nextSteps(facts, day).map((s) => <li key={s} className="small">{s}</li>)}</ul>
      {err && <p className="alert alert--error" role="alert"><span>{err}</span></p>}
      <div className="row">
        <button className="btn btn--primary" type="button" disabled={pending} data-testid={`${testId}-submit`}
          onClick={() => start(async () => {
            setErr(null);
            // the page is not refreshed when the access ends now: the confirmation stays on screen, then Sign out
            const x = await opsAct<Sent>('staff_resign', { last_day: day, reason: reason.trim() || null }, endsNow(facts, day) ? [] : refresh);
            if (!x.ok) { setErr(x.message); return; }
            setSent(x.data); setStep('done');
          })}>{pending ? 'Sending' : endsNow(facts, day) ? 'Confirm: I leave today' : 'Confirm my resignation'}</button>
        <button className="btn btn--ghost" type="button" disabled={pending} onClick={() => setStep('form')}>Back</button>
      </div>
    </div>
  );
}
