import './data-health.css';
import Link from 'next/link';
import { Act } from '@/features/admin/Act';
import { door } from '@/server/door';
import { checkedWords, fixedWords, splitChecks, type DataHealth } from './model';

// Data health on Admin > To do (migration 0441; the owner: "i shouldnt be spotting this myself, u should be telling me this
// and fixing it urself"). The nightly self-check: one line per problem with its count, opened for the records, each with
// its link and, where it is safe, a one-tap fix. The clear-cut cases (test accounts on real work, duplicate tasks, tasks
// already done) are fixed by the database without asking; the card says how many. Admins only: for anyone else the
// read is refused and the card is not shown.

// the fixes' buttons (the database names the action; the words are the card's)
const FIX: Record<string, string> = { mark_picked_up: 'Mark picked up', close_booking: 'Close', close_task: 'Close', unassign_task: 'Unassign',
  unassign_lead: 'Unassign', unassign_field_job: 'Unassign', restart_followup: 'Restart follow-up' };
export async function DataHealthCard({ userId }: { userId: string }) {
  const d = await door<DataHealth>(userId, 'ops_read', 'data_health').catch(() => null);
  if (!d) return null;
  return <DataHealthView d={d} />;
}

export function DataHealthView({ d, now }: { d: DataHealth; now?: Date }) {
  const { open, clear } = splitChecks(d.checks);
  const fixed = fixedWords(d.fixed_week ?? d.fixed);
  const issues = open.reduce((n, c) => n + c.count, 0);
  return (
    <section id="data-health" className={`pt-card ad-card dh${issues ? ' dh--open' : ''}`} aria-labelledby="dh-h" data-testid="data-health">
      <div className="pt-card__head">
        <h2 className="d4" id="dh-h">Data health{issues > 0 && <span className="dh__count" data-testid="data-health-count">{issues}</span>}</h2>
        <span className="dh__when small muted">
          {d.ran_at ? checkedWords(d.ran_at, now) : 'Runs every night'}
          <Act ops action="data_health_run" label="Check now" variant="quiet" done="Checked." testId="data-health-run" />
        </span>
      </div>
      {!d.ran_at ? (
        <p className="small" data-testid="data-health-none">The first check runs tonight. Press Check now to run it.</p>
      ) : open.length === 0 ? (
        <p className="dh__clear small" data-testid="data-health-clear"><span className="dh__tick" aria-hidden="true">
          <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"><path d="M4 10.5l4 4 8-9" /></svg></span>
          All {clear.length} checks clear.</p>
      ) : (
        <ul className="dh__list">
          {open.map((c) => (
            <li key={c.key} className="dh__check" data-testid={`data-health-${c.key}`}>
              <details>
                <summary>
                  <span className="dh__n num">{c.count}</span>
                  <span className="dh__line">{c.line}</span>
                  <span className="dh__more" aria-hidden="true" />
                </summary>
                <ul className="dh__items">
                  {c.items.map((i, n) => (
                    <li key={i.id ?? `${c.key}-${n}`} className="dh__item">
                      {i.href ? <Link prefetch={false} className="link" href={i.href}>{i.text}</Link> : <span>{i.text}</span>}
                      {i.fix && i.id && <Act ops action="data_health_fix" payload={{ action: i.fix.action, id: i.id }} label={FIX[i.fix.action] ?? i.fix.label} done="Fixed."
                        confirm={i.fix.action === 'close_booking' || i.fix.action === 'mark_picked_up' ? 'This records the pickup (and the return for Close) at the booked times, as Bookings > Now does.' : undefined}
                        testId={`data-health-fix-${c.key}-${n}`} />}
                    </li>))}
                </ul>
                {c.count > c.items.length && <p className="dh__rest small muted">The first {c.items.length} of {c.count}.{c.href && <> <Link prefetch={false} className="link" href={c.href}>See them all</Link></>}</p>}
              </details>
            </li>))}
        </ul>
      )}
      {d.ran_at && (open.length > 0 || fixed) && (
        <p className="dh__foot small muted" data-testid="data-health-foot">
          {open.length > 0 && clear.length > 0 && <>{clear.length} other checks clear. </>}
          {fixed && <>Fixed without asking this week: {fixed}.</>}
        </p>)}
    </section>
  );
}
