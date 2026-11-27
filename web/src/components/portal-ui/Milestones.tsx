'use client';
import { useEffect, useState, type ReactNode } from 'react';
import Link from '@/components/Link';
import { motionOK } from '@/lib/motion';
import { playMoment } from '@/features/motion/moment';

// r50 hotfix 2 (the owner's reel of a stepped tracker): one tracker for every process that runs in steps: a booking from
// the request to the pickup, an owner's application, the staff steps from the sale to the pickup, the Rewards tiers.
// A step is a round node on a line: done (a black node with a check), now (the red ring, its number, "your turn" or
// "our turn"), later (grey). The line fills to the step to do now. The server renders the final state, so nothing moves
// the layout; what this device has not seen yet (a step done since the last visit) ticks in as its stretch of line draws,
// and when the last step is done the finish row lights up with a confetti moment, once per device. Motion is transform
// and opacity only, 300 ms or less, and off under reduced motion (styles/motion.css). Each step is a button that opens
// its detail (what it means, when it was done, where to do it), so the tracker answers a tap.
export type MilestoneState = 'done' | 'now' | 'later';
export interface Milestone { key: string; label: string; state: MilestoneState; hint?: string | null; when?: string | null; href?: string | null; cta?: string | null;
  /** now: the person acts on it (else the team does) */ yours?: boolean;
  /** done because it does not apply (drawn dashed, no check) */ skipped?: boolean;
  /** now: whose turn, in the viewer's words (else Your turn / Our turn) */ turn?: string }

const WORD: Record<MilestoneState, string> = { done: 'done', now: 'now', later: 'later' };

/** "Step 3 of 6: Sign and pay" or the finish words. Pure: the server pages and the tests share it. */
export function milestoneSummary(steps: Milestone[], finish = 'All done'): { done: number; total: number; text: string } {
  const done = steps.filter((s) => s.state === 'done').length;
  const cur = steps.find((s) => s.state === 'now');
  return { done, total: steps.length, text: cur ? `Step ${steps.indexOf(cur) + 1} of ${steps.length}: ${cur.label}` : done === steps.length ? finish : `${done} of ${steps.length} done` };
}

/** The steps done that this device had not seen done (the ones that tick in). */
export function freshlyDone(steps: Milestone[], seen: string[] | null): string[] {
  if (!seen) return [];
  return steps.filter((s) => s.state === 'done' && !seen.includes(s.key)).map((s) => s.key);
}

export function Milestones({ steps, storageKey, testId = 'milestones', stepTestId, label, finish = 'All done', finishNote, celebrate = true, children }: {
  steps: Milestone[]; storageKey: string; testId?: string; /** one test id for every step (with data-step), instead of testId-key */ stepTestId?: string; label: string; finish?: string; finishNote?: ReactNode; celebrate?: boolean; children?: ReactNode;
}) {
  const sum = milestoneSummary(steps, finish);
  const complete = sum.total > 0 && sum.done === sum.total;
    const [fresh, setFresh] = useState<string[]>([]);
  const [open, setOpen] = useState<string | null>(steps.find((s) => s.state === 'now')?.key ?? null);
  const [said, setSaid] = useState('');
  const doneKeys = steps.filter((s) => s.state === 'done').map((s) => s.key).join(',');

  useEffect(() => {
    const key = `cc-ms-${storageKey}`;
    let seen: string[] | null = null;
    try { const v = localStorage.getItem(key); seen = v === null ? null : v.split(',').filter(Boolean); localStorage.setItem(key, doneKeys); } catch { return; }
    const list = freshlyDone(steps, seen);
    if (!list.length) return;
    const t = setTimeout(() => {
      setFresh(list);
      setSaid(`Done: ${steps.filter((s) => list.includes(s.key)).map((s) => s.label).join(', ')}. ${sum.text}.`);
      if (complete && celebrate && motionOK()) playMoment('tier');
    }, 0);
    return () => clearTimeout(t);
    // once per page view: the steps come from the server
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [storageKey, doneKeys]);

  return (
    <div className="ms" data-testid={testId} data-step={sum.done} data-complete={complete || undefined}>
      <div className="ms__head">
        <p className="ms__count" aria-hidden="true"><b>{sum.done}</b>/{sum.total}</p>
        <p className="ms__sum">{sum.text}</p>
      </div>
      <ol className="ms__list" aria-label={label}>
        {steps.map((s, i) => {
          const isOpen = open === s.key;
          const detail = s.hint || s.when || (s.href && s.cta && s.state !== 'done');
          return (
            <li key={s.key} className={`ms__step${fresh.includes(s.key) ? ' is-new' : ''}`} data-state={s.state} aria-current={s.state === 'now' ? 'step' : undefined} data-skip={s.skipped || undefined} data-step={s.key} data-testid={stepTestId ?? `${testId}-${s.key}`}>
              <span className="ms__node" aria-hidden="true">
                {s.skipped ? '-' : s.state === 'done' ? <svg viewBox="0 0 16 16" width="16" height="16"><path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" /></svg> : i + 1}
              </span>
              <div className="ms__body">
                {detail ? (
                  <button type="button" className="ms__label" aria-expanded={isOpen} onClick={() => setOpen(isOpen ? null : s.key)} data-testid={`${testId}-${s.key}-toggle`}>
                    {s.label}<span className="vh">, {s.skipped ? 'not needed' : WORD[s.state]}</span>
                  </button>
                ) : <span className="ms__label">{s.label}<span className="vh">, {WORD[s.state]}</span></span>}
                {s.state === 'now' && <span className={`ms__turn${s.yours ? ' is-yours' : ''}`}>{s.turn ?? (s.yours ? 'Your turn' : 'Our turn: nothing to do for now')}</span>}
                {s.state === 'done' && s.when && !isOpen && <span className="ms__when">{s.when}</span>}
                {isOpen && detail && (
                  <div className="ms__detail" data-testid={`${testId}-${s.key}-detail`}>
                    {s.hint && <p>{s.hint}</p>}
                    {s.when && <p className="ms__when">{s.when}</p>}
                    {s.href && s.cta && s.state !== 'done' && <Link prefetch={false} className={`btn btn--sm ${s.state === 'now' && s.yours ? 'btn--primary' : 'btn--ghost'}`} href={s.href}>{s.cta}</Link>}
                  </div>
                )}
              </div>
            </li>
          );
        })}
        <li className="ms__step ms__finish" data-state={complete ? 'done' : 'later'} data-testid={`${testId}-finish`}>
          <span className="ms__node ms__node--finish" aria-hidden="true">
            <svg viewBox="0 0 24 24" width="18" height="18"><path d="M5 3v18M5 4h11l-2 4 2 4H5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round" strokeLinecap="round" /></svg>
          </span>
          <div className="ms__body"><span className="ms__label">{finish}</span>{complete && finishNote ? <span className="ms__when">{finishNote}</span> : null}</div>
        </li>
      </ol>
      {children}
      <p className="vh" aria-live="polite" data-testid={`${testId}-live`}>{said}</p>
    </div>
  );
}
