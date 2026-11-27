'use client';
import type { ReactNode } from 'react';
import Link from '@/components/Link';
import { Milestones, type Milestone } from '@/components/portal-ui/Milestones';
import type { Stage, Todo } from './next-action';

// r40: the booking's steps, done, now and later, in plain words (the owner: "make things that need to be done very
// obvious"). r50 hotfix 2: drawn by the shared stepped tracker (Milestones: a node per step on a line, a check that pops
// for a step done since the last visit, the finish flag and its confetti when the car is back and the statement out),
// each step opening what it means and where to do it. The to-do list stays under it.
const HINT: Record<string, string> = {
  offer: 'We check the car and the dates and send you an offer with the price. You approve it in one tap.',
  'sign-pay': 'Sign the rental agreement and pay: the car is then reserved for you.',
  verify: 'Your licence photos and selfie, and your proof of insurance (or our protection plan).',
  pickup: 'Bring your original licence and the card you paid with. The walk-around of the car takes about 10 minutes.',
  return: 'Bring it back on time with the same fuel or charge. The return photos take a minute.',
  statement: 'Your final statement: the deposit released and every charge explained.'
};

/** The booking's stages as tracker steps (pure). */
export function stageMilestones(stages: Stage[]): Milestone[] {
  return stages.map((s) => ({ key: s.key, label: s.label, state: s.state, hint: HINT[s.key] ?? null, href: s.href ?? null, cta: s.href ? 'Do it now' : null, yours: s.yours }));
}

/** todos: the booking's one to-do list (still needed, the quick links), each with its small button, under the stages;
 *  children: a to-do done in place (the agreement's details form on the booking page). */
export function StepTracker({ number, stages, todos = [], testId = 'step-tracker', children }: { number: string; stages: Stage[]; todos?: Todo[]; testId?: string; children?: ReactNode }) {
  return (
    <Milestones steps={stageMilestones(stages)} storageKey={`booking-${number}`} testId={testId} label={`Steps for booking ${number}`} finish="Trip complete"
      finishNote="Thanks for driving with CarmaCars.">
      {(todos.length > 0 || children) && <>
        <p className="pu-eyebrow" id={`${testId}-todo-h`}>To do</p>
        {todos.length > 0 && <ul className="pt-steps" aria-labelledby={`${testId}-todo-h`} data-testid={`${testId}-todo`}>
          {todos.map((t) => (
            <li key={t.key} className={t.tone === 'ok' ? 'is-done' : t.tone === 'bad' ? 'is-now' : ''} data-tone={t.tone} data-testid={`todo-${t.key.split(':').pop()}`}>
              <span>
                {t.label}
                <small>{t.state}{t.reason ? `: ${t.reason}` : ''}</small>
                {t.href && t.cta && <Link prefetch={false} className="btn btn--ghost btn--sm" style={{ marginTop: 'var(--s-1)' }} href={t.href} data-testid="todo-action" data-guide="todo-action">{t.cta}</Link>}
              </span>
            </li>
          ))}
        </ul>}
        {children}
      </>}
    </Milestones>
  );
}
