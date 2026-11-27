import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Card } from '@/features/admin/ui';
import { door } from '@/server/door';
import '@/features/townhall/townhall.css';
import './admin-call.css';
import { WEEKDAYS, openDecisions, scheduleWords, type AdminCall as T, type Item } from './model';

// r50 hotfix 2 (5150): the weekly Admin call for the two principals. The deck builds itself before each call from the live
// data (the townhall's engine: one slide a section, points, lines, notes); each decision on it has Approve and Deny in
// place, done by the database with the same rules as the item's own screen (money never moves from here); the call is
// in the site (Join), with the weekly invite in every Admin's calendar and the day and time editable here and in
// Settings > Program settings.
const when = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'long', month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));
const day = (d: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', month: 'long', day: 'numeric' }).format(new Date(`${d}T12:00:00Z`));

function Decide({ deck, i }: { deck: string; i: Item }) {
  const refresh = ['/admin/admin-call'];
  if (i.decision) {
    return <span className={`ac-done ac-done--${i.decision}`} data-testid={`ac-decided-${i.key}`}>{i.decision === 'approve' ? i.approve : i.deny}: {i.decided_by}{i.decision_note ? `, "${i.decision_note}"` : ''}</span>;
  }
  return (<span className="ac-acts">
    <Act action="admin_call_decide" payload={{ deck, key: i.key, decision: 'approve' }} label={i.approve} refresh={refresh} done="Approved." testId={`ac-approve-${i.key}`}
      confirm={i.kind === 'money' || i.kind === 'payout' || i.kind === 'deposit' ? 'This records the decision and puts a To do for it. No money moves from here: it moves only from its own screen, with its checks.' : undefined} />
    <Act action="admin_call_decide" payload={{ deck, key: i.key, decision: 'deny' }} label={i.deny} variant="quiet" refresh={refresh} done="Recorded." testId={`ac-deny-${i.key}`}
      fields={[{ name: 'note', label: 'Why (optional, kept with the decision)', type: 'text' }]} />
  </span>);
}

export async function AdminCallDeck({ userId, week }: { userId: string; week?: string }) {
  const v = await door<T>(userId, 'admin_read', 'admin_call', { week_of: week && /^\d{4}-\d{2}-\d{2}$/.test(week) ? week : null });
  const refresh = ['/admin/admin-call'];
  const d = v.deck;
  const dec = d ? openDecisions(d.slides) : { open: 0, total: 0 };
  return (<>
    <Card title={v.next_at ? `Next call: ${when(v.next_at)}` : 'Weekly Admin call'} testId="ac-next"
      aside={<Act action="admin_call_build" payload={{ week_of: d?.week_of ?? null }} label={d ? 'Build again' : 'Build the deck now'} refresh={refresh} done="Built from the live data." testId="ac-build" />}>
      <p className="small" data-testid="ac-when">{scheduleWords(v)}. The deck builds itself the day before and again three hours before the call.</p>
      <div className="row">
        {v.in_site ? <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/admin-call/live" data-testid="ac-join">Join the call</Link>
          : <span className="small muted" data-testid="ac-join-off">The call in the site is switched off (Townhall, outside link): use your own link for now.</span>}
        <a className="btn btn--ghost btn--sm" href="/api/admin-call-ics" download="carmacars-admin-call.ics" data-testid="ac-ics">Add to my calendar (every week)</a>
        <Act action="admin_call_schedule" label="Change the day or time" refresh={refresh} done="Saved: the invites are updated." testId="ac-schedule"
          fields={[{ name: 'weekday', label: 'Day', type: 'select', required: true, value: String(v.weekday), options: [1, 2, 3, 4, 5, 6, 7].map((n) => [String(n), WEEKDAYS[n]!] as [string, string]) },
            { name: 'time', label: 'Time (Toronto, HH:MM)', type: 'text', required: true, value: v.time },
            { name: 'minutes', label: 'Length (minutes)', type: 'number', min: 15, max: 240, value: v.minutes }]} />
      </div>
      <p className="small muted">Each Admin gets the weekly calendar invite by email, and an update when the day or time changes. Also in Settings, Program settings (Admin call).</p>
      {v.weeks.length > 1 && <p className="small">Other weeks: {v.weeks.map((w) => <Link key={w} prefetch={false} className="link" href={`/admin/admin-call?week=${w}`}> {day(w)}</Link>)}</p>}
    </Card>
    {!d ? <p className="small muted" data-testid="ac-empty">The first deck builds itself the day before the call. Build it now to see this week&apos;s.</p> : <>
      <p className="small muted" data-testid="ac-built">The call of {when(d.call_at)}. Built {when(d.built_at)}. {dec.total ? `${dec.open} of ${dec.total} decisions still open.` : 'No decision waiting.'}</p>
      <nav className="ac-toc" aria-label="Sections of the deck">{d.slides.map((s, i) => <a key={s.key} className="ac-toc__a" href={`#ac-${s.key}`}>{i + 1}. {s.title}{s.items?.some((x) => !x.decision) ? <span className="pt__count">{s.items.filter((x) => !x.decision).length}</span> : null}</a>)}</nav>
      <ol className="th-deck stack" data-testid="ac-deck">{d.slides.map((s, i) => (
        <li key={s.key} id={`ac-${s.key}`} className="pt-card ad-card stack" data-testid={`ac-slide-${s.key}`}>
          <h2 className="d3">{i + 1}. {s.title}</h2>
          {!!s.points.length && <dl className="th-points">{s.points.map((p) => <div key={p.label}><dt className="small muted">{p.label}</dt><dd className="d4 num">{p.value}</dd></div>)}</dl>}
          {!!s.lines?.length && <ul className="small ac-lines">{s.lines.map((l, j) => <li key={`${j}-${l}`}>{l}</li>)}</ul>}
          {!!s.items?.length && <ul className="ac-items" aria-label={`Decisions: ${s.title}`}>{s.items.map((it) => (
            <li key={it.key} className="ac-item" data-testid={`ac-item-${it.key}`} data-decision={it.decision ?? 'open'}>
              <div className="ac-item__text"><b>{it.label}</b>{it.detail && <span className="small muted"> {it.detail}</span>}{' '}
                <Link prefetch={false} className="link small" href={it.href}>Open</Link></div>
              <Decide deck={d.id} i={it} />
            </li>))}</ul>}
          {!s.items?.length && !s.lines?.length && !s.points.some((p) => p.value !== '0' && p.value !== '$0.00') && <p className="small muted">Nothing this week.</p>}
          {s.note && <p className="small th-shout" data-testid={`ac-note-${s.key}`}>{s.note}</p>}
          <Act action="admin_call_note" payload={{ deck: d.id, key: s.key }} label={s.note ? 'Change the note' : 'Add a note'} variant="quiet" refresh={refresh} done="Saved."
            fields={[{ name: 'note', label: 'What to say or do on this slide', type: 'textarea', value: s.note ?? '' }]} />
        </li>))}</ol>
    </>}
  </>);
}
