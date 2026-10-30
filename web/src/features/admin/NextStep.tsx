import type { ReactNode } from 'react';
import Link from 'next/link';
import type { NextStep } from './next-step';

// The booking's next step (next-step.ts), under the status at the top of the Admin and staff booking pages: one
// sentence, who does it, and at most one button.
export function NextStepPanel({ s }: { s: NextStep }) {
  return (
    <section className="ad-next" aria-labelledby="next-step-h" data-testid="next-step" data-step={s.step}>
      <div className="ad-next__text">
        <h2 className="ad-next__h" id="next-step-h">Next step</h2>
        <p className="ad-next__say" data-testid="next-step-text">{s.text}</p>
        <p className="small muted" data-testid="next-step-who">Who: {s.who}</p>
      </div>
      {s.action && <Link prefetch={false} className="btn btn--primary btn--sm" href={s.action.href} data-testid={s.action.testId}>{s.action.label}</Link>}
    </section>
  );
}

// The other actions of the booking in one menu (details and summary: opens with Enter or Space, every action inside is
// a normal button or link). Nothing shows when no action applies.
export function MoreActions({ children }: { children: ReactNode }) {
  const items = (Array.isArray(children) ? children : [children]).flat(Infinity).filter((c) => c !== null && c !== undefined && c !== false && c !== '');
  if (!items.length) return null;
  return (
    <details className="ad-more" data-testid="more-actions">
      <summary className="btn btn--ghost btn--sm" data-testid="more-actions-open">More actions</summary>
      <div className="ad-more__menu" role="group" aria-label="More actions">{children}</div>
    </details>
  );
}
