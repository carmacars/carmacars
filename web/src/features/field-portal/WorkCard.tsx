'use client';
import { useState } from 'react';
import Link from '@/components/Link';
import { Plate } from '@/features/field/Plate';
import { FdIcon } from '@/features/field/icons';
import { maps } from '@/features/field/format';
import { ContactButtons } from '@/features/phone/QuoButtons';
import { StartChecklist } from '@/features/field/StartChecklist';
import { cardSteps, cardTitle, clockText, nextStep, type Card } from './model';
import { AddonTicks, CarUpdate, CleanCheck, PhotoStart, PrepItems } from './Steps';

// One card of the Today list (r35 part X): one car and time. The time, what it is, the car and its plate, the steps of the card
// ticked as they are done, one big button for the next step (it opens that step right on the card), and the rest folded under
// More: the place in maps, the renter's call or text, helping the renter, what stops the pickup.
export function WorkCard({ c, now }: { c: Card; now: number }) {
  const [open, setOpen] = useState(false);
  const step = nextStep(c);
  const steps = cardSteps(c);
  const at = c.at ? new Date(c.at).getTime() : null;
  const soon = !c.done && at !== null && at - now < 90 * 60_000 && at - now > -3 * 3_600_000;
  const t = c.at ? clockText(c.at).split(' ') : null;
  const spare = !c.must;
  const kindClass = c.leg === 'return' ? ' is-return' : spare ? ' is-spare' : '';
  const jobHref = c.type === 'job' && c.id ? `/staff/field/jobs/${c.id}` : null;
  const primary = () => {
    // a pickup or return: one tap acknowledges and starts it and opens its screen (0130); the testids are the ones the e2e knows
    if (step.what === 'open' && c.id && (c.leg === 'pickup' || c.leg === 'return')) return <StartChecklist job={c.id} status={c.status ?? 'scheduled'} label={step.label} testId={c.leg === 'pickup' ? 'field-checkout' : 'field-checkin'} />;
    if (step.what === 'open' && jobHref) return <Link prefetch={false} className="btn btn--primary fd-wide" href={jobHref} data-testid="card-go">{step.label}</Link>;
    if (step.what === 'done') return <p className="fp-done"><FdIcon name="check" />Done</p>;
    return <button type="button" className={`btn ${open ? 'btn--ghost' : 'btn--primary'} fd-wide`} aria-expanded={open} onClick={() => setOpen(!open)} data-testid="card-go">{open ? 'Close' : step.label}</button>;
  };
  return (
    <li className={`fp-card${c.done ? ' is-done' : ''}${spare ? ' is-spare' : ''}${soon ? ' is-now' : ''}`} data-testid={c.type === 'job' ? 'job-card' : 'work-card'} data-type={c.type}>
      <div className="fp-card__top">
        {t && c.type !== 'prep' ? <p className="fp-card__time">{t[0]}<small>{t.slice(1).join(' ')}</small></p> : <span />}
        <span className={`fp-card__kind${kindClass}`}>{cardTitle(c)}</span>
      </div>
      <div>
        <p className="fp-card__car">{c.vehicle.name}</p>
        <div className="fp-card__id">{c.vehicle.plate && <Plate plate={c.vehicle.plate} small />}
          {c.booking && <span className="small">{[c.booking.renter, c.booking.number].filter(Boolean).join(', ')}</span>}</div>
      </div>
      {c.place && <p className="fp-card__place"><FdIcon name="pin" /><span>{c.place}</span></p>}
      {c.type === 'service' && c.why && <p className="fp-card__why">{c.why}</p>}
      {c.type === 'service' && c.update && <p className="small">Last update: {c.update.status.replace(/_/g, ' ')}{c.update.note ? `, ${c.update.note}` : ''}{c.update.by ? ` (${c.update.by})` : ''}</p>}
      {c.type === 'clean' && <p className="small">{c.days != null ? `Last checked clean ${c.days} day${c.days === 1 ? '' : 's'} ago.` : 'No clean check on record yet.'}</p>}
      {steps.length > 0 && <ol className="fp-steps" aria-label="Steps">{steps.map((s) => (
        <li key={s.label} className={s.done ? 'is-done' : ''}><span className="fp-steps__mark" aria-hidden="true">{s.done ? <FdIcon name="check" /> : null}</span>{s.label}<span className="vh">{s.done ? ', done' : ', to do'}</span></li>))}</ol>}
      {c.instructions && <p className="small"><b>From the office:</b> {c.instructions}</p>}
      {primary()}
      {open && step.what === 'clean' && <CleanCheck c={c} onDone={() => setOpen(false)} />}
      {open && step.what === 'addons' && <AddonTicks addons={c.addons ?? []} />}
      {open && step.what === 'update' && <CarUpdate c={c} />}
      {open && step.what === 'photos' && <PhotoStart c={c} />}
      {open && step.what === 'prep' && <PrepItems c={c} />}
      {jobHref && <p className="small"><Link prefetch={false} className="link" href={jobHref} data-testid="open-job">Open the {c.leg === 'return' ? 'return' : c.leg === 'pickup' ? 'pickup' : 'job'}</Link></p>}
      {(c.place || c.booking) && !c.done && (
        <details className="fp-more">
          <summary>More</summary>
          <div className="fp-more__body">
            {c.place && <a className="btn btn--ghost fd-wide" href={maps(c.place)} target="_blank" rel="noreferrer"><FdIcon name="pin" />Open in maps</a>}
            {c.booking?.mobile && <ContactButtons phone={c.booking.mobile} name={c.booking.renter} booking={c.booking.number} btnClass="btn btn--ghost fd-wide" testId="card-renter">Call {c.booking.renter ?? 'the renter'}</ContactButtons>}
            {c.booking && <Link prefetch={false} className="btn btn--ghost fd-wide" href={`/staff/field/help/${c.booking.number}`} data-testid="card-help"><FdIcon name="help" />Help the renter: pay, deposit, ID, sign</Link>}
            {c.addons && c.addons.length > 0 && step.what !== 'addons' && <AddonTicks addons={c.addons} />}
            {(c.blockers?.length ?? 0) > 0 && <><p className="small"><b>What stops the pickup now</b></p><ul className="fp-blockers">{c.blockers!.map((b) => <li key={b.code}>{b.label}</li>)}</ul></>}
          </div>
        </details>)}
    </li>
  );
}
