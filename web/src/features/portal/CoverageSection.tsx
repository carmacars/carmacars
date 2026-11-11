'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { UploadCard } from './UploadCard';
import { InsurerSelect } from '@/features/insurers/InsurerSelect';
import { requestProtectionPlan, setCoverageOption } from '@/server/actions/portal';
import type { RenterCoverage } from '@/features/coverage/types';
import type { CardRow } from '@/features/coverage/cards';
import { CardPicker } from '@/features/coverage/CardPicker';
import { TypedInput } from '@/components/DateInput';
import { money } from '@/lib/format';

// Coverage for damage to the car (migration 0071), on the booking's verification page:
//   option 1, OPCF 27: insurer, policy number, expiry after the return date, then the pink slip and the OPCF 27
//   endorsement page (1401: both before payment), each a PDF or photos; our team approves or rejects with a reason.
//   option 2, credit card coverage: only on the credit card that paid (never debit or prepaid) in the renter's name;
//   the renter picks the card from the list and sees whether it covers this car (1400), then ticks and confirms; the
//   card's benefit document is optional.
// The car is not handed over until the coverage is confirmed.
const OPCF_PAGES: Array<[string, string, string]> = [
  ['pink_slip', 'Pink slip', 'Your liability insurance card (the pink slip), with the policy number and dates.'],
  ['endorsement', 'OPCF 27 endorsement page', 'The page of your policy that lists the OPCF 27 endorsement (Liability for Damage to Non-Owned Automobiles).']];
const fmtDay = (d: string) => new Date(`${d}T12:00:00`).toLocaleDateString('en-CA', { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric' });

export function CoverageSection({ number, c, cards = [] }: { number: string; c: RenterCoverage; cards?: CardRow[] }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [msg, setMsg] = useState('');
  const [d, setD] = useState<Record<string, string>>({ insurer_name: c.proof?.insurer_name ?? '', policy_number: c.proof?.policy_number ?? '', policy_expiry: c.proof?.policy_expiry ?? '' });
  const run = (f: () => Promise<{ ok: boolean; message?: string }>, done: string) => start(async () => {
    const r = await f(); setMsg(r.ok ? done : (r.message ?? 'Something went wrong.')); if (r.ok) router.refresh();
  });
  const p = c.proof && c.proof.option === c.option ? c.proof : null;
  const pages = p?.pages ?? [];
  const missing = c.opcf27_missing ?? [];
  const sent = (k: string) => pages.some((x) => x.status !== 'rejected' && c.page_kinds?.[x.id] === k);
  const field = (k: string, label: string, props: React.InputHTMLAttributes<HTMLInputElement> = {}) => (
    <div className="field"><label className="label" htmlFor={`pt-cov-${k}`}>{label}</label>
      <TypedInput className="input" id={`pt-cov-${k}`} value={d[k] ?? ''} onChange={(e) => setD({ ...d, [k]: e.target.value })} required {...props} /></div>);
  const details1Ok = !!(d.insurer_name?.trim() && d.policy_number?.trim() && d.policy_expiry && d.policy_expiry >= c.min_policy_expiry);
  return (
    <div className="stack" data-testid="coverage-section">
      <p><b>{c.option_label}</b>{c.confirmed ? <span data-testid="coverage-confirmed"> · confirmed</span> : null}</p>
      {c.confirmed && <p className="small">Your coverage is confirmed for this rental.</p>}
      {c.last_switch && (
        <p className="small" data-testid="coverage-switched">On {fmtDay(c.last_switch.at.slice(0, 10))} our team changed your coverage from {c.last_switch.from_label} to {c.last_switch.to_label}. Your total went from {money(c.last_switch.total_before_cents, { cents: true })} to {money(c.last_switch.total_after_cents, { cents: true })}.{c.last_switch.note ? ` ${c.last_switch.note}` : ''}</p>)}
      {!c.confirmed && p?.status === 'rejected' && p.rejection_reason && (
        <p className="alert alert--error" role="alert" data-testid="coverage-rejected"><span className="alert__title">We could not accept it</span><span>{p.rejection_reason}</span></p>)}

      {c.option === 1 && !c.confirmed && (
        <div className="stack">
          <p className="small">Send two pages of your own auto policy: the pink slip (your liability insurance card) and the OPCF 27 endorsement page, each a PDF or a photo. The policy must still be active after your return on {fmtDay(c.return_date)}. Our team checks them before pickup.</p>
          <div className="field"><label className="label" htmlFor="pt-cov-insurer_name">Insurer</label>
            <InsurerSelect id="pt-cov-insurer_name" value={d.insurer_name ?? ''} onChange={(v) => setD((x) => ({ ...x, insurer_name: v }))} required testId="coverage-insurer" /></div>
          <div className="field-row">{field('policy_number', 'Policy number', { maxLength: 60 })}{field('policy_expiry', 'Policy expiry', { type: 'date', min: c.min_policy_expiry })}</div>
          {d.policy_expiry && d.policy_expiry < c.min_policy_expiry && <p className="error" role="alert">The policy must still be active after your return date.</p>}
          {pages.length > 0 && <p className="small" data-testid="coverage-pages">{pages.length} {pages.length === 1 ? 'page' : 'pages'} sent{p?.status === 'submitted' ? ', in review' : ''}.</p>}
          {missing.length > 0 && <p className="alert alert--warn" role="note" data-testid="coverage-opcf-missing">
            <span>Still needed: {missing.join(' and ')}.{c.opcf27_before_payment !== false && c.booking_status === 'pending_payment' ? ' Your booking is paid and confirmed once both are sent.' : ''}</span></p>}
          {pages.length < c.max_pages && (details1Ok
            ? <div className="pt-uploads">{OPCF_PAGES.map(([k, title, hint]) => (
                <UploadCard key={k} number={number} kind="coverage_proof" driverId={null} details={{ ...d, coverage_option: '1', page_kind: k }}
                  title={sent(k) ? `${title}: sent (add another page)` : title} hint={hint} />))}</div>
            : <p className="small muted">Enter the insurer, the policy number and the expiry to send the pink slip and the endorsement page.</p>)}
        </div>)}

      {c.option === 2 && !c.confirmed && (
        <div className="stack">
          {!c.card.eligible && c.card.message && <p className="alert alert--error" role="alert" data-testid="coverage-card-problem"><span>{c.card.message}</span></p>}
          <p className="small muted">Not sure your card covers this car? <a className="link" href="/credit-card-rental-coverage" target="_blank" rel="noopener">See which cards include rental car coverage and their car value limits</a>, then confirm with your card issuer.</p>
          {c.card.eligible && <p className="small" data-testid="coverage-card">Paid with the {c.card.brand ? c.card.brand.toUpperCase() : 'card'} credit card ending {c.card.last4}, in your name.</p>}
          {c.card.eligible && !p?.renter_confirmed_at && (
            <CardPicker number={number} cards={cards} pick={c.card_pick ?? null} vehicleClass={c.vehicle_class} rentalDays={c.rental_days} />)}
          {p?.renter_confirmed_at && <p className="small" data-testid="coverage-card-confirmed">You confirmed your card&apos;s coverage{c.card_pick?.label ? ` (${c.card_pick.label})` : ''}. Our team checks it before pickup.</p>}
          {p?.renter_confirmed_at && c.card_pick?.check.result === 'not_covered' && (
            <p className="alert alert--error" role="alert" data-testid="coverage-card-pick-problem"><span className="alert__title">Your card no longer covers this car</span><span>{c.card_pick.check.message}</span></p>)}
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
