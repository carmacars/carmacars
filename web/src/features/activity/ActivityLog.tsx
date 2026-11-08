import './activity.css';
import Link from '@/components/Link';
import type { ReactNode } from 'react';
import { ContactButtons } from '@/features/phone/QuoButtons';
import { NoteRemove } from './NoteRemove';
import { TYPE_LABEL, activityQuery, byDay, hiddenFields, itemAction, itemMeta, logHref, P, type ActivityItem, type ActivityPage } from './model';

const clock = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));

export interface ActivityLogProps {
  data: ActivityPage | null;
  /** the page the log is on (the booking page passes its ?tab=activity) */
  base: string;
  sp: Record<string, string | undefined>;
  /** where the email composer is (Reply), the live chat inbox, the texts and calls inbox; null hides that action */
  emailHref: string | null; chatBase: string | null; inbox: string | null;
  /** the renter, for Call and Text */
  phone: string | null | undefined; name: string | null | undefined; booking?: string | null;
  /** an Admin removes a note from the log */
  canRemoveNotes?: boolean;
  /** more above the list (the note box) */
  children?: ReactNode;
}

// The renter's Activity log (migration 0850, release 35): everything about the renter (or the booking) in one list, newest
// first, with a chip per type (All by default), a search, and Older for the next 50. Every action stays one press away:
// Email (Reply on an email from the renter), Call and Text (on a call or text from them), and Open the chat.
export function ActivityLog({ data, base, sp, emailHref, chatBase, inbox, phone, name, booking, canRemoveNotes = false, children }: ActivityLogProps) {
  const q = activityQuery(sp);
  const path = base.split('?')[0]!;
  const contact = (only?: 'call' | 'text', testId = 'activity-contact') => phone
    ? <ContactButtons phone={phone} name={name} booking={booking ?? null} inbox={inbox} only={only} testId={testId} /> : null;
  const action = (i: ActivityItem) => {
    const a = itemAction(i, { emailHref, chatBase, inbox });
    if (!a) return null;
    if (a.kind === 'reply') return <Link prefetch={false} className="btn btn--ghost btn--sm" href={a.href} data-testid="activity-reply">Reply</Link>;
    if (a.kind === 'text') return contact('text', 'activity-text-back');
    if (a.kind === 'call') return contact('call', 'activity-call-back');
    return <Link prefetch={false} className="link small" href={a.href}>{a.label}</Link>;
  };
  return (
    <section className="pt-card ad-card al" id="activity" aria-labelledby="activity-h" data-testid="activity-log">
      <div className="al-head">
        <h2 className="d4" id="activity-h">Activity</h2>
        <div className="al-acts">
          {emailHref && <Link prefetch={false} className="btn btn--ghost btn--sm" href={emailHref} data-testid="activity-email">Email</Link>}
          {contact()}
        </div>
      </div>
      {children}
      {data && <>
        <ul className="al-chips" aria-label="Show">
          <li><Link prefetch={false} scroll={false} className="al-chip" href={logHref(base, sp, { type: null })} aria-current={q.type ? undefined : 'true'} data-testid="activity-chip-all">All</Link></li>
          {data.types.map((t) => <li key={t}><Link prefetch={false} scroll={false} className="al-chip" href={logHref(base, sp, { type: t })} aria-current={q.type === t ? 'true' : undefined} data-testid={`activity-chip-${t}`}>{TYPE_LABEL[t]}</Link></li>)}
        </ul>
        <form className="al-search" method="get" action={path} role="search">
          {hiddenFields(base, sp).map(([k, v]) => <input key={k} type="hidden" name={k} value={v} />)}
          <label className="vh" htmlFor="activity-q">Search the activity</label>
          <input id="activity-q" className="input" type="search" name={P.q} defaultValue={q.q} maxLength={100} placeholder="Search the activity" data-testid="activity-search" />
          <button type="submit" className="btn btn--ghost btn--sm">Search</button>
          {q.q && <Link prefetch={false} className="link small" href={logHref(base, sp, { q: null })}>Clear</Link>}
        </form>
      </>}
      {!data ? <p className="small muted">The activity could not be read. Reload the page.</p>
        : data.items.length === 0 ? <p className="small muted" data-testid="activity-empty">{q.type || q.q ? 'Nothing matches. Choose All or clear the search.' : 'Nothing yet.'}</p>
        : byDay(data.items).map((g) => (
          <div key={g.day}>
            <p className="al-day">{g.day}</p>
            <ol className="al-list">{g.items.map((i) => {
              const meta = itemMeta(i);
              return (
                <li key={i.k} className={`al-item${i.dir === 'in' ? ' is-in' : ''}`} data-testid="activity-item" data-type={i.type}>
                  <time dateTime={i.at} suppressHydrationWarning>{clock(i.at)}</time>
                  <div className="al-main">
                    <p><span className="al-type">{TYPE_LABEL[i.type]}</span><b>{i.title}</b>{meta && <span className="small muted"> · {meta}</span>}</p>
                    {i.body && <p className="small al-body">{i.body}</p>}
                    {i.type === 'call' && i.extra?.next_steps?.length ? <p className="small"><b>Next steps:</b> {i.extra.next_steps.join(' ')}</p> : null}
                    {action(i) && <p className="al-acts">{action(i)}</p>}
                    {canRemoveNotes && i.type === 'note' && <p className="al-acts"><NoteRemove id={i.k.slice(5)} /></p>}
                  </div>
                </li>
              );
            })}</ol>
          </div>
        ))}
      {data && (q.before || data.more) && <p className="al-more">
        {q.before && <Link prefetch={false} className="btn btn--ghost btn--sm" href={logHref(base, sp, { before: null, k: null })} data-testid="activity-newest">Newest</Link>}
        {data.more && data.next && <Link prefetch={false} className="btn btn--ghost btn--sm" href={logHref(base, sp, { before: data.next.before, k: data.next.before_k })} data-testid="activity-older">Older</Link>}
      </p>}
    </section>
  );
}
