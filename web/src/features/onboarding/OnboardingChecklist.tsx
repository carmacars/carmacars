import Link from '@/components/Link';
import './onboarding.css';
import { baseFor, carSteps, ownerStep, STATE_TEXT, type Overview, type Step } from './steps';

// The one Onboarding checklist (r34, 0823), in the owner portal, on the owner page of Admin and staff, and in the staff
// portals: per car, each step with its state, who it waits on or why it is blocked, and its one next action.
function Row({ s }: { s: Step }) {
  return (
    <li className={`ob-step ob-step--${s.state}`} data-testid="onboarding-step" data-step={s.code} data-state={s.state}>
      <span className="ob-step__mark" aria-hidden="true" />
      <span className="ob-step__text">
        <b className="ob-step__label">{s.label}<span className="vh">: {STATE_TEXT[s.state]}</span></b>
        {(s.waiting || s.why) && <span className="ob-step__why">{[s.state === 'blocked' ? 'Blocked.' : s.waiting, s.why].filter(Boolean).join(' ')}</span>}
      </span>
      <span className="ob-step__act">
        {s.action?.href ? <Link prefetch={false} className={`btn btn--sm ${s.state === 'waiting' ? 'btn--primary' : 'btn--ghost'}`} href={s.action.href} data-testid="onboarding-step-action">{s.action.label}</Link>
          : <span className={`badge ${s.state === 'done' ? 'badge--outline' : s.state === 'blocked' ? 'badge--grey' : s.state === 'not_needed' ? 'badge--grey' : 'badge--outline'}`}>{STATE_TEXT[s.state]}</span>}
      </span>
    </li>
  );
}

export function OnboardingChecklist({ data, only, title = 'Onboarding checklist', testId = 'onboarding-checklist' }: { data: Overview | null; only?: string; title?: string; testId?: string }) {
  if (!data) return null;
  const b = baseFor(data.viewer, data.owner.id);
  const cars = data.cars.filter((c) => !only || c.vehicle_id === only);
  const me = ownerStep(data, b);
  const owner = data.viewer === 'owner';
  return (
    <section className="pt-card stack ob" aria-labelledby={`${testId}-h`} data-testid={testId}>
      <div className="pt-card__head"><h2 className="d4" id={`${testId}-h`}>{title}</h2></div>
      <p className="small muted">{owner ? 'What is done, what is next and who it waits on. The button on a step is the one thing to do for it.'
        : 'Each step of the owner\'s onboarding: done, waiting on someone, or blocked and why. The button is the next thing to do.'}</p>
      {!only && <ol className="ob-steps" aria-label={me.label}><Row s={me} /></ol>}
      {cars.length === 0 && <p className="small" data-testid="onboarding-none">{owner ? 'Every car of yours is on the road: nothing left to do here.' : 'No car of this owner is onboarding.'}</p>}
      {cars.map((c) => {
        const s = carSteps(c, data, b);
        return (
          <div key={c.vehicle_id} className="ob-car stack" data-testid="onboarding-car" data-vehicle={c.vehicle_id}>
            {!only && <h3 className="d5">{owner ? <Link prefetch={false} className="link" href={b.carHref(c.vehicle_id)}>{c.name}</Link> : c.name}{c.plate ? <span className="small muted"> {c.plate}</span> : null}</h3>}
            <p className="small" data-testid="onboarding-progress">{s.done} of {s.total} done.{s.next ? <> Next: <b>{s.next.label}</b>{s.next.waiting ? ` (${s.next.waiting.toLowerCase()})` : ''}.</> : ' Nothing waiting.'}</p>
            <ol className="ob-steps" aria-label={`Onboarding of the ${c.name}`}>{s.steps.map((x) => <Row key={x.code} s={x} />)}</ol>
          </div>
        );
      })}
    </section>
  );
}
