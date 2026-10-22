'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { UploadCard } from './UploadCard';
import { confirmCardCoverage, requestProtectionPlan, setCoverageOption } from '@/server/actions/portal';
import type { RenterCoverage } from '@/features/coverage/types';

// Coverage for damage to the car (migration 0071), on the booking's verification page:
//   option 1, OPCF 27: insurer, policy number, expiry after the return date, and the policy or endorsement as a PDF or
//   photos (several pages); our team approves or rejects it with a reason shown here.
//   option 2, credit card coverage: only on the credit card that paid (never debit or prepaid) in the renter's name;
//   the renter ticks that it covers this car and this length; the card's benefit document is optional.
// The car is not handed over until the coverage is confirmed.
const fmtDay = (d: string) => new Date(`${d}T12:00:00`).toLocaleDateString('en-CA', { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' });

export function CoverageSection({ number, c }: { number: string; c: RenterCoverage }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState('');
  const [tick, setTick] = useState(false);
  const [d, setD] = useState<Record<string, string>>({ insurer_name: c.proof?.insurer_name ?? '', policy_number: c.proof?.policy_number ?? '', policy_expiry: c.proof?.policy_expiry ?? '' });
  const run = (f: () => Promise<{ ok: boolean; message?: string }>, done: string) => start(async () => {
    const r = await f(); setMsg(r.ok ? done : (r.message ?? 'Something went wrong.')); if (r.ok) router.refresh();
  });
  const p = c.proof && c.proof.option === c.option ? c.proof : null;
  const pages = p?.pages ?? [];
  const field = (k: string, label: string, props: React.InputHTMLAttributes<HTMLInputElement> = {}) => (
    <div className="field"><label className="label" htmlFor={`pt-cov-${k}`}>{label}</label>
      <input className="input" id={`pt-cov-${k}`} value={d[k] ?? ''} onChange={(e) => setD({ ...d, [k]: e.target.value })} required {...props} /></div>);
  const details1Ok = !!(d.insurer_name?.trim() && d.policy_number?.trim() && d.policy_expiry && d.policy_expiry >= c.min_policy_expiry);
  return (
    <div className="stack" data-testid="coverage-section">
      <p><b>{c.option_label}</b>{c.confirmed ? <span data-testid="coverage-confirmed"> · confirmed</span> : null}</p>
      {c.confirmed && <p className="small">Your coverage is confirmed for this rental.</p>}
      {!c.confirmed && p?.status === 'rejected' && p.rejection_reason && (
        <p className="alert alert--error" role="alert" data-testid="coverage-rejected"><span className="alert__title">We could not accept it</span><span>{p.rejection_reason}</span></p>)}

      {c.option === 1 && !c.confirmed && (
        <div className="stack">
          <p className="small">Send your policy document or the OPCF 27 endorsement: a PDF, or photos of each page. It must still be active after your return on {fmtDay(c.return_date)}. Our team checks it before pickup.</p>
          {field('insurer_name', 'Insurer', { maxLength: 120 })}
          <div className="field-row">{field('policy_number', 'Policy number', { maxLength: 60 })}{field('policy_expiry', 'Policy expiry', { type: 'date', min: c.min_policy_expiry })}</div>
          {d.policy_expiry && d.policy_expiry < c.min_policy_expiry && <p className="error" role="alert">The policy must still be active after your return date.</p>}
          {pages.length > 0 && <p className="small" data-testid="coverage-pages">{pages.length} {pages.length === 1 ? 'page' : 'pages'} sent{p?.status === 'submitted' ? ', in review' : ''}.</p>}
          {pages.length < c.max_pages && (details1Ok
            ? <UploadCard number={number} kind="coverage_proof" driverId={null} details={{ ...d, coverage_option: '1' }} title={pages.length ? 'Add another page' : 'Policy page or OPCF 27 endorsement'}
                hint="A PDF, or a photo of each page. Every page goes together in one review." />
            : <p className="small muted">Enter the insurer, the policy number and the expiry to send the document.</p>)}
        </div>)}

      {c.option === 2 && !c.confirmed && (
        <div className="stack">
          {!c.card.eligible && c.card.message && <p className="alert alert--error" role="alert" data-testid="coverage-card-problem"><span>{c.card.message}</span></p>}
          {c.card.eligible && <p className="small" data-testid="coverage-card">Paid with the {c.card.brand ? c.card.brand.toUpperCase() : 'card'} credit card ending {c.card.last4}, in your name.</p>}
          {c.card.eligible && !p?.renter_confirmed_at && (
            <form className="stack" onSubmit={(e) => { e.preventDefault(); run(() => confirmCardCoverage(number, tick, ''), 'Thanks. Our team checks it before pickup.'); }}>
              <label className="check"><input type="checkbox" checked={tick} onChange={(e) => setTick(e.target.checked)} data-testid="coverage-card-tick" />{' '}
                <span>This credit card includes rental car coverage for a {c.vehicle_class ?? 'car of this class'} for {c.rental_days} {c.rental_days === 1 ? 'day' : 'days'}, and I will claim on it if the car is damaged.</span></label>
              <button className="btn btn--primary" type="submit" disabled={!tick || pending} data-testid="coverage-card-confirm">{pending ? 'Saving' : 'Confirm my card’s coverage'}</button>
            </form>)}
          {p?.renter_confirmed_at && <p className="small" data-testid="coverage-card-confirmed">You confirmed your card&apos;s coverage. Our team checks it before pickup.</p>}
          {c.card.eligible && <UploadCard number={number} kind="coverage_proof" driverId={null} details={{ coverage_option: '2' }} title="Card benefit document (optional)"
            hint="It helps our check: the page of your card's benefits that covers rental cars." />}
        </div>)}

      {c.option === 4 && <p className="small" data-testid="coverage-included">Insurance is included with this car: no personal auto policy is needed and there is nothing to send.</p>}
      {c.option === 3 && <p className="small">{c.confirmed ? 'The CarmaCars Protection Plan is active for this rental.' : 'You chose the CarmaCars Protection Plan. We send you its terms before pickup.'}</p>}

      {c.can_change && !c.confirmed && (
        <div className="row" style={{ flexWrap: 'wrap', gap: 'var(--s-3)' }}>
          {c.option !== 1 && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => run(() => setCoverageOption(number, 1), 'Changed to option 1.')} data-testid="coverage-to-1">Use OPCF 27 on my policy instead</button>}
          {c.option !== 2 && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => run(() => setCoverageOption(number, 2), 'Changed to option 2.')} data-testid="coverage-to-2">Use my credit card&apos;s coverage instead</button>}
          {!c.protection_plan_requested && <button className="btn btn--quiet btn--sm" type="button" disabled={pending} onClick={() => run(() => requestProtectionPlan(number, ''), 'We will send you the Protection Plan’s price and terms.')} data-testid="coverage-plan">Ask for the Protection Plan</button>}
        </div>)}
      {msg && <p className="small" role="status" data-testid="coverage-msg">{msg}</p>}
    </div>
  );
}
