'use client';
import './usage.css';
import { useId, useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { adminAct } from '@/server/actions/admin-portal';
import { capProblem, paidCost, shortLabel, usd, type ServiceState } from './model';

// The usage guard's question (migration 0080): an included allowance is used up. The pop-up says what continuing costs
// at the current rates and asks: allow paid usage until the end of today or this month, up to an amount, or keep it
// paused. Nobody answering keeps it paused. The database records the answer (app.usage_decide) and opens the gates.
export function UsageAllow({ s, testId = 'usage-allow' }: { s: ServiceState; testId?: string }) {
  const router = useRouter();
  const dlg = useRef<HTMLDialogElement>(null);
  const idp = useId().replace(/:/g, '');
  const [until, setUntil] = useState<'day' | 'month'>(s.period === 'month' ? 'month' : 'day');
  const [cap, setCap] = useState(s.service === 'workers_ai' ? '1' : s.service === 'claude' ? '2' : '5');
  const [err, setErr] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const cost = paidCost(s);
  const name = shortLabel(s.label);
  const decide = (decision: 'allow' | 'keep_paused') => {
    const problem = decision === 'allow' ? capProblem(cap) : null;
    if (problem) { setErr(problem); return; }
    setErr(null);
    start(async () => {
      const r = await adminAct('usage_decide', { service: s.service, decision, until, cap_usd: decision === 'allow' ? Number(cap.replace(/[$,\s]/g, '')) : null }, ['/admin', '/admin/settings/usage']);
      if (!r.ok) { setErr(r.message); return; }
      dlg.current?.close();
      router.refresh();
    });
  };
  if (!cost.canPay) return null;
  return (
    <>
      <span className="row">
        <button type="button" className="btn btn--primary btn--sm" aria-haspopup="dialog" data-testid={testId} onClick={() => { setErr(null); dlg.current?.showModal(); }}>Allow paid usage</button>
        {s.decision?.decision !== 'keep_paused' && s.state === 'paused' && (
          <button type="button" className="btn btn--ghost btn--sm" disabled={pending} data-testid={`${testId}-keep`} onClick={() => decide('keep_paused')}>Keep paused</button>)}
      </span>
      <dialog ref={dlg} className="ad-dialog" aria-labelledby={`${idp}-t`} data-testid={`${testId}-dialog`}>
        <h2 className="d4" id={`${idp}-t`}>Allow paid {name} usage?</h2>
        <p className="small">The included {name} for {s.period === 'day' ? 'today' : 'this month'} is used: {s.used_text} of {s.included_text}. Until you answer, it stays paused and nothing is charged.</p>
        <dl className="pt-dl ad-kv" data-testid={`${testId}-cost`}>
          <div><dt>Rate</dt><dd>{cost.rate}</dd></div>
          <div><dt>For example</dt><dd>{cost.example}</dd></div>
          <div><dt>While paused</dt><dd>{s.when_used_up}</dd></div>
        </dl>
        <form className="ad-form" noValidate onSubmit={(e) => { e.preventDefault(); decide('allow'); }}>
          <fieldset className="ad-fieldset">
            <legend className="small"><b>Allow paid usage until</b></legend>
            {s.period === 'day' && <label className="row small"><input type="radio" name={`${idp}-until`} checked={until === 'day'} onChange={() => setUntil('day')} data-testid={`${testId}-day`} /> the end of today</label>}
            <label className="row small"><input type="radio" name={`${idp}-until`} checked={until === 'month'} onChange={() => setUntil('month')} data-testid={`${testId}-month`} /> the end of this month</label>
          </fieldset>
          <div className="field">
            <label className="field__label" htmlFor={`${idp}-cap`}>Up to (US dollars, the most it may cost)</label>
            <input className="input" id={`${idp}-cap`} inputMode="decimal" value={cap} onChange={(e) => setCap(e.target.value)} aria-invalid={!!err} aria-describedby={err ? `${idp}-err` : undefined} data-testid={`${testId}-cap`} />
          </div>
          {err && <p className="alert alert--error" role="alert" id={`${idp}-err`}><span>{err}</span></p>}
          <div className="row">
            <button className="btn btn--primary btn--sm" type="submit" disabled={pending} data-testid={`${testId}-submit`}>{pending ? 'Working' : `Allow up to ${usd(Number(cap.replace(/[$,\s]/g, '')) || 0)}`}</button>
            <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => decide('keep_paused')} data-testid={`${testId}-dialog-keep`}>Keep paused</button>
            <button className="btn btn--quiet btn--sm" type="button" onClick={() => dlg.current?.close()}>Close</button>
          </div>
        </form>
      </dialog>
    </>
  );
}
