'use client';
import { useEffect, useRef, useState } from 'react';
import Link from '@/components/Link';
import { motionOK } from '@/lib/motion';
import { ChecklistProgress } from '@/features/motion/Progress';
import { newlyDone, stageSummary, type Stage } from './next-action';

// r40: the booking's steps, done, now and later, in plain words (the owner: "make things that need to be done very
// obvious"). On the shared pieces: the checklist bar (ChecklistProgress) and the step list of the owner's onboarding and
// the licence page (.pt-steps). The server renders the final state, so nothing moves the layout; what the renter has not
// seen yet (a step done since the last visit on this device) ticks in and the bar advances from where it was, and the
// screen reader hears the change (aria-live).
const WORD: Record<Stage['state'], string> = { done: 'done', now: 'now', later: 'later' };

export function StepTracker({ number, stages, testId = 'step-tracker' }: { number: string; stages: Stage[]; testId?: string }) {
  const sum = stageSummary(stages);
  const root = useRef<HTMLDivElement>(null);
  const [fresh, setFresh] = useState<string[]>([]);
  const [said, setSaid] = useState('');
  const doneKeys = stages.filter((s) => s.state === 'done').map((s) => s.key).join(',');
  useEffect(() => {
    const key = `cc-steps-${number}`;
    let seen: string[] | null = null;
    try { const v = localStorage.getItem(key); seen = v === null ? null : v.split(',').filter(Boolean); localStorage.setItem(key, doneKeys); } catch { return; }
    const list = newlyDone(stages, seen);
    if (!list.length) return;
    const t = setTimeout(() => {
      setFresh(list);
      const names = stages.filter((s) => list.includes(s.key)).map((s) => s.label).join(', ');
      setSaid(`Done: ${names}. ${sum.text}.`);
    }, 0);
    // the bar advances from where it was at the last visit, not from empty
    const fill = root.current?.querySelector<HTMLElement>('.ck-progress__fill');
    if (fill && motionOK() && typeof fill.animate === 'function') {
      const from = Math.max(0, sum.done - list.length) / sum.total;
      fill.getAnimations().forEach((a) => a.cancel());
      fill.animate([{ transform: `scaleX(${from})` }, { transform: `scaleX(${sum.done / sum.total})` }], { duration: 900, delay: 250, easing: 'cubic-bezier(0.16, 1, 0.3, 1)', fill: 'backwards' });
    }
    return () => clearTimeout(t);
    // once per page view: the stages come from the server
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [number, doneKeys]);

  return (
    <div ref={root} className="stack" data-testid={testId} data-step={sum.done}>
      <ChecklistProgress done={sum.done} total={sum.total} label={`Steps for booking ${number}`} testId={`${testId}-bar`} />
      <ol className="pt-steps" aria-label={`Steps for booking ${number}`}>
        {stages.map((s) => (
          <li key={s.key} className={s.state === 'done' ? `is-done${fresh.includes(s.key) ? ' is-new' : ''}` : s.state === 'now' ? 'is-now' : ''}
            aria-current={s.state === 'now' ? 'step' : undefined} data-state={s.state} data-testid={`${testId}-${s.key}`}>
            <span>
              {s.state !== 'done' && s.href ? <Link prefetch={false} className="link" href={s.href}>{s.label}</Link> : s.label}
              <span className="vh">, {WORD[s.state]}</span>
              {s.state === 'now' && <small>{s.yours ? 'Your turn: do this now.' : 'Our turn: nothing to do for now.'}</small>}
            </span>
          </li>
        ))}
      </ol>
      <p className="vh" aria-live="polite" data-testid={`${testId}-live`}>{said}</p>
    </div>
  );
}
