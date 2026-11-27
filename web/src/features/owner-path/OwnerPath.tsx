import Link from '@/components/Link';
import '@/features/onboarding/onboarding.css';
import './owner-path.css';
import { ownerPath, type SignStatus } from './path';
import { Milestones } from '@/components/portal-ui/Milestones';

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
      {/* r50 hotfix 2: the shared stepped tracker */}
      <Milestones steps={p.steps.map((s) => ({ key: s.code, label: s.label, state: s.state === 'done' ? 'done' : s.state === 'current' ? 'now' : 'later', hint: s.note, yours: s.state === 'current' && !!s.action }))}
        storageKey="owner-path" stepTestId="owner-path-step" testId="owner-path-ms" label="Your steps with CarmaCars" finish="Ready for your first car" />
    </section>
  );
}
