import Link from '@/components/Link';
import { NEED_STATUS, needHref, needProgress, needsAction, orderNeeds, type StillNeeded as Needs } from './still-needed';
import './still-needed.css';

// What we still need from you (migration 1203): a prominent checklist at the top of /account and of each request and
// booking that is not complete. Each item has its status (needed, under review, not accepted with the reason, done) and
// one button; the bar shows how far along it is. The items and statuses are the database's (app.renter_still_needed).
/** quiet (r40): the page's Do this next card holds the one red button, so the items' buttons are plain and the phone's
 *  bottom bar is the card's. */
export function StillNeeded({ number, needs, title, carLabel, testId, quiet }: { number: string; needs: Needs; title?: string; carLabel?: string; testId?: string; quiet?: boolean }) {
  const items = orderNeeds(needs.items);
  const pct = needProgress(needs);
  const todo = needsAction(needs);
  const id = `still-needed-${number}`;
  return (
    <section className="sn" aria-labelledby={`${id}-h`} data-testid={testId ?? 'still-needed'} data-todo={todo}>
      <div className="sn__head">
        <h2 className="sn__title" id={`${id}-h`}>{title ?? 'What we still need from you'}</h2>
        {carLabel && <p className="sn__for">{carLabel}</p>}
        <p className="sn__count" data-testid="still-needed-count">{todo > 0 ? `${todo} ${todo === 1 ? 'thing' : 'things'} to do` : 'We are checking what you sent'}, {needs.done} of {needs.total} done</p>
        <div className="sn__bar" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={pct} aria-label="How much is done" data-testid="still-needed-bar">
          <span style={{ width: `${pct}%` }} />
        </div>
      </div>
      <ul className="sn__list">
        {items.map((i) => {
          const s = NEED_STATUS[i.status];
          return (
            <li key={i.key} className="sn__item" data-tone={s.tone} data-testid={`still-needed-item-${i.key.split(':')[0]}`} data-status={i.status}>
              <span className="sn__mark" aria-hidden="true">{i.status === 'done' ? '✓' : i.status === 'rejected' ? '!' : i.status === 'review' ? '…' : ''}</span>
              <span className="sn__text">
                <span className="sn__label">{i.label}</span>
                <span className="sn__state">{s.word}{i.reason ? `: ${i.reason}` : ''}</span>
              </span>
              {i.action && <Link prefetch={false} className={`btn btn--sm ${i.status === 'review' || quiet ? 'btn--ghost' : 'btn--primary'} sn__btn`} href={needHref(number, i.action.path)} data-testid="still-needed-action">{i.action.label}</Link>}
            </li>
          );
        })}
      </ul>
      {/* r38 (owner, Nov 11): the next thing to do, kept in view at the bottom of a phone's screen */}
      {!quiet && (() => { const n = items.find((i) => (i.status === 'missing' || i.status === 'rejected') && i.action); return n?.action ? (
        <div className="sn__next" data-testid="still-needed-next"><Link prefetch={false} className="btn btn--primary btn--sm" href={needHref(number, n.action.path)}>Next: {n.label}</Link></div>) : null; })()}
    </section>
  );
}
