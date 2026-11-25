import Link from '@/components/Link';
import '@/features/onboarding/onboarding.css';
import './owner-path.css';
import { ownerPath, type SignStatus } from './path';

// Sign first, then cars (r50, 3800): the owner portal's guided path. The six steps in plain words, the current one
// marked, and one big button for the one thing to do now. Nothing shows once every step is done.
export function OwnerPathCard({ status }: { status: SignStatus | null }) {
  const p = status ? ownerPath(status) : null;
  if (!p || !p.current) return null;
  const c = p.current;
  return (
    <section className="pt-card pt-card--next stack op" aria-labelledby="op-h" data-testid="owner-path" data-guide="owner-path" data-step={c.code}>
      <p className="pt-kicker">Step {p.done + 1} of {p.steps.length}</p>
      <h2 className="d3" id="op-h">{c.label}</h2>
      <p className="op-note">{c.note}</p>
      {c.action && <p><Link prefetch={false} className="btn btn--primary btn--lg op-cta" href={c.action.href} data-testid="owner-path-cta" data-guide="owner-path-cta">{c.action.label}</Link></p>}
      <ol className="ob-steps op-steps" aria-label="Your steps with CarmaCars">
        {p.steps.map((s, i) => (
          <li key={s.code} className={`ob-step op-step ob-step--${s.state === 'done' ? 'done' : s.state === 'current' ? 'waiting' : 'blocked'}`} data-testid="owner-path-step" data-step={s.code} data-state={s.state}
            aria-current={s.state === 'current' ? 'step' : undefined}>
            <span className="ob-step__mark" aria-hidden="true" />
            <span className="ob-step__text"><b className="ob-step__label">{i + 1}. {s.label}<span className="vh">: {s.state === 'done' ? 'done' : s.state === 'current' ? 'now' : 'later'}</span></b>
              {s.state !== 'current' && s.state === 'done' && <span className="ob-step__why">{s.note}</span>}</span>
            <span className="ob-step__act"><span className={`badge ${s.state === 'current' ? '' : 'badge--outline'}`}>{s.state === 'done' ? 'Done' : s.state === 'current' ? 'Now' : 'Later'}</span></span>
          </li>))}
      </ol>
    </section>
  );
}
