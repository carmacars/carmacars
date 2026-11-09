import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Card } from '@/features/admin/ui';
import { door } from '@/server/door';
import data from '@/features/investor/updates-data.json';
import { withReleases, releasesOfWeek, type Release, type Townhall as T } from './model';

// The weekly townhall deck (1062): one slide a section, the platform updates from the release notes of that week, the
// notes an Admin types per slide; the next call with its link and the calendar invite. Admin builds it again any time.
const when = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'long', month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));
const day = (d: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', month: 'long', day: 'numeric' }).format(new Date(`${d}T12:00:00Z`));

export async function TownhallDeck({ userId, aal, base, week }: { userId: string; aal?: 'aal1' | 'aal2' | null; base: '/admin' | '/staff'; week?: string }) {
  const v = await door<T>(userId, 'ops_read', 'townhall', { week_of: week && /^\d{4}-\d{2}-\d{2}$/.test(week) ? week : null }, aal);
  const refresh = [`${base}/townhall`];
  const slides = v.deck ? withReleases(v.deck.slides, releasesOfWeek(data as unknown as Release[], v.deck.week_of)) : [];
  return (<>
    <Card title={v.next_at ? `Next call: ${when(v.next_at)}, ${v.minutes} minutes` : 'Weekly townhall'} testId="townhall-next"
      aside={v.admin ? <Act action="townhall_build" payload={{ week_of: v.deck?.week_of ?? null }} label="Build again" refresh={refresh} done="Built from the live data." testId="townhall-build" /> : null}>
      <p className="small">{v.call_url ? <a className="btn btn--sm btn--primary" href={v.call_url} target="_blank" rel="noopener noreferrer">Join the call</a> : 'The call link is set in Program settings (Townhall call link).'}{' '}
        <a className="link small" href="/api/townhall-ics" download="carmacars-townhall.ics">Add to my calendar (every week)</a></p>
      {v.weeks.length > 1 && <p className="small">Other weeks: {v.weeks.map((w) => <Link key={w} prefetch={false} className="link" href={`${base}/townhall?week=${w}`}> {day(w)}</Link>)}</p>}
    </Card>
    {!v.deck ? <p className="small muted">The first deck is built on Sunday night from the week&apos;s live data.</p> : <>
      <p className="small muted">The week of {day(v.deck.week_of)}. Built {when(v.deck.built_at)}.</p>
      <ol className="th-deck stack" data-testid="townhall-deck">{slides.map((s, i) => (
        <li key={s.key} className="pt-card ad-card stack" data-testid={`townhall-slide-${s.key}`}>
          <h2 className="d3">{i + 1}. {s.title}{s.admin_only ? <span className="ad-b ad-b--light"> Admin</span> : null}</h2>
          {!!s.points.length && <dl className="th-points">{s.points.map((p) => <div key={p.label}><dt className="small muted">{p.label}</dt><dd className="d4">{p.value}</dd></div>)}</dl>}
          {!!s.lines?.length && <ul className="small">{s.lines.map((l) => <li key={l}>{l}</li>)}</ul>}
          {!!s.board?.length && <><p className="small"><b>Leaderboard</b></p><ol className="small">{s.board.map((p) => <li key={p.label}>{p.label}: {p.value}</li>)}</ol></>}
          {s.note && <p className="small" data-testid={`townhall-note-${s.key}`}>{s.note}</p>}
          {v.admin && <Act action="townhall_note" payload={{ deck: v.deck!.id, key: s.key }} label={s.note ? 'Change the note' : 'Add a note'} refresh={refresh} done="Saved."
            fields={[{ name: 'note', label: 'What to say on this slide', type: 'textarea', value: s.note ?? '' }]} />}
        </li>))}</ol>
    </>}
  </>);
}
