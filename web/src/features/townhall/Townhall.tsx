import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Card } from '@/features/admin/ui';
import { door } from '@/server/door';
import data from '@/features/investor/updates-data.json';
import './townhall.css';
import { WEEKDAY, runClock, visitorDays, withReleases, releasesOfWeek, type Release, type Townhall as T } from './model';

// The weekly townhall deck (1062): one slide a section, the platform updates from the release notes of that week, the
// notes an Admin types per slide; the next call with its link and the calendar invite. Admin builds it again any time.
const when = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'long', month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));
const day = (d: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', month: 'long', day: 'numeric' }).format(new Date(`${d}T12:00:00Z`));

export async function TownhallDeck({ userId, aal, base, week }: { userId: string; aal?: 'aal1' | 'aal2' | null; base: '/admin' | '/staff'; week?: string }) {
  const v = await door<T>(userId, 'ops_read', 'townhall', { week_of: week && /^\d{4}-\d{2}-\d{2}$/.test(week) ? week : null }, aal);
  const refresh = [`${base}/townhall`];
  const slides = v.deck ? withReleases(v.deck.slides, releasesOfWeek(data as unknown as Release[], v.deck.week_of)) : [];
  const clock = runClock(slides);
  return (<>
    <Card title={v.next_at ? `Next call: ${when(v.next_at)}, ${v.minutes} minutes` : 'Weekly townhall'} testId="townhall-next"
      aside={v.admin ? <Act action="townhall_build" payload={{ week_of: v.deck?.week_of ?? null }} label="Build again" refresh={refresh} done="Built from the live data." testId="townhall-build" /> : null}>
      <p className="small">{v.call_url ? <a className="btn btn--sm btn--primary" href="/api/townhall-join" target="_blank" rel="noopener noreferrer" data-testid="townhall-join">Join the call</a> : 'The call link is set in Program settings (Townhall call link).'}{' '}
        {v.joined_unconfirmed && !v.checked_in ? <Act ops action="townhall_attend" payload={{ method: 'confirm' }} label="Confirm I am in the call" variant="primary" refresh={refresh} done="Confirmed: you count as there." testId="townhall-confirm" /> : null}{' '}
        {v.checked_in ? <span className="ad-b ad-b--light" data-testid="townhall-checked-in">You are checked in</span>
          : v.can_check_in ? <Act ops action="townhall_attend" payload={{ method: 'checkin' }} label="Check in" variant="primary" refresh={refresh} done="Checked in." testId="townhall-checkin" /> : null}{' '}
        <a className="link small" href="/api/townhall-ics" download="carmacars-townhall.ics">Add to my calendar (every week)</a></p>
      <p className="small muted">Every staff member is expected, cameras on. Join through this page and confirm you are in the call, or check in (from 15 minutes before): that counts you as there. Two townhalls missed in a row lock your account until an Admin restores it.</p>
      <p className="small" data-testid="townhall-when">Every {WEEKDAY[v.weekday] ?? 'week'} at {v.time} Toronto time. Field applicants&apos; live calls take the hour before.</p>
      {v.admin && <Act action="townhall_schedule" label="Change the day or time" refresh={refresh} done="Saved: the reminders and the field calls follow." testId="townhall-schedule"
        fields={[{ name: 'weekday', label: 'Day', type: 'select', required: true, value: String(v.weekday), options: [1, 2, 3, 4, 5, 6, 7].map((d) => [String(d), WEEKDAY[d]!] as [string, string]) },
          { name: 'time', label: 'Time (Toronto, HH:MM)', type: 'text', required: true, value: v.time }]} />}
      {v.admin && visitorDays(v.visitors).length > 0 && <details data-testid="townhall-visitors"><summary className="link small">Website visitors by weekday (last 8 weeks)</summary>
        <table className="small"><tbody>{visitorDays(v.visitors).map((r) => <tr key={r.day}><th scope="row">{r.name}</th><td>{r.sessions.toLocaleString('en-CA')}{r.quietest ? ' (quietest)' : ''}</td></tr>)}</tbody></table></details>}
      {v.admin && v.attendance && v.attendance.meetings > 0 && <p className="small" data-testid="townhall-attendance">Last townhall: {v.attendance.last_absent ?? 0} missed it. Each person&apos;s misses are on the staff list.</p>}
      {v.weeks.length > 1 && <p className="small">Other weeks: {v.weeks.map((w) => <Link key={w} prefetch={false} className="link" href={`${base}/townhall?week=${w}`}> {day(w)}</Link>)}</p>}
    </Card>
    {/* r35 part C (1505): the craziest story of the week, the recordings, and the Admin's social figures and attendance */}
    <Card title="Craziest story of the week" testId="townhall-stories" aside={<Act ops action="townhall_story_submit" label="Tell yours" refresh={refresh} done="Sent. An Admin picks one for the townhall." testId="townhall-story-submit"
      fields={[{ name: 'body', label: 'What happened (a few sentences)', type: 'textarea', required: true }]} />}>
      {!!v.my_stories?.length && <ul className="small" data-testid="townhall-my-stories">{v.my_stories.map((x) => <li key={x.id}>{x.body}{x.picked ? <b> (picked for the townhall)</b> : null}</li>)}</ul>}
      {v.admin && v.stories && (v.stories.length ? <ul className="small" data-testid="townhall-story-list">{v.stories.map((x) => (
        <li key={x.id}><b>{x.name}:</b> {x.body} {x.picked ? <span className="ad-b ad-b--light">Picked</span>
          : <Act ops action="townhall_story_pick" payload={{ id: x.id }} label="Pick this one" refresh={refresh} done="Picked: it is on the deck." testId={`townhall-pick-${x.id}`} />}</li>))}</ul>
        : <p className="small muted">No stories this week yet.</p>)}
      {!v.admin && !v.my_stories?.length && <p className="small muted">Something wild happened with a renter, a car or a delivery? Tell it: one is picked for the townhall.</p>}
    </Card>
    {(v.recordings?.length || v.admin) ? <Card title="Recordings" testId="townhall-recordings">
      {v.recordings?.length ? <ul className="small">{v.recordings.map((r) => <li key={r.week_of}><a className="link" href={r.url} target="_blank" rel="noopener noreferrer" data-testid={`townhall-recording-${r.week_of}`}>The week of {day(r.week_of)}</a></li>)}</ul>
        : <p className="small muted">No recording yet.</p>}
      {v.admin && v.deck && <Act ops action="townhall_recording" payload={{ deck: v.deck.id }} label={v.deck.recording_url ? 'Change this week\'s recording' : 'Add this week\'s recording'} refresh={refresh} done="Saved: every portal shows it." testId="townhall-recording-set"
        fields={[{ name: 'url', label: 'Recording link (https://)', type: 'text', value: v.deck.recording_url ?? '' }]} />}
    </Card> : null}
    {v.admin && v.mark && <Card title="Attendance" testId="townhall-mark">
      <p className="small muted">{v.mark.meeting_at ? `The townhall of ${when(v.mark.meeting_at)}.` : 'No townhall yet.'} Mark anyone who was there without joining through the site, or who was not.</p>
      <ul className="small">{v.mark.people.map((p) => <li key={p.user_id} data-testid={`townhall-mark-${p.user_id}`}>{p.name}: {p.present ? 'there' : 'not there'}{p.locked ? ' (locked: two missed)' : ''}{' '}
        <Act ops action="townhall_mark" payload={{ user_id: p.user_id, present: !p.present, meeting_at: v.mark!.meeting_at }} label={p.present ? 'Mark absent' : 'Mark present'} refresh={refresh} done="Saved." /></li>)}</ul>
    </Card>}
    {v.admin && <Card title="Social media this week" testId="townhall-social" aside={<Act ops action="townhall_social_save" label="Enter figures" refresh={refresh} done="Saved: on the deck." testId="townhall-social-save"
      fields={[{ name: 'platform', label: 'Platform', type: 'select', required: true, options: [['instagram', 'Instagram'], ['tiktok', 'TikTok'], ['facebook', 'Facebook'], ['youtube', 'YouTube'], ['google', 'Google'], ['x', 'X'], ['linkedin', 'LinkedIn']] },
        { name: 'followers', label: 'Followers', type: 'number', min: 0 }, { name: 'posts', label: 'Posts this week', type: 'number', min: 0 }, { name: 'views', label: 'Views this week', type: 'number', min: 0 },
        { name: 'week_of', label: 'Week (any day of it; empty: this week)', type: 'date' }]} />}>
      {v.social?.length ? <ul className="small">{v.social.map((x) => <li key={`${x.week_of}-${x.platform}`}>{day(x.week_of)}, {x.platform}: {x.followers ?? '-'} followers, {x.posts ?? '-'} posts, {x.views ?? '-'} views</li>)}</ul>
        : <p className="small muted">No figures yet. There is no API for these: enter them each week.</p>}
    </Card>}
    {!v.deck ? <p className="small muted">The first deck is built on Sunday night from the week&apos;s live data.</p> : <>
      <p className="small muted">The week of {day(v.deck.week_of)}. Built {when(v.deck.built_at)}.{v.run_minutes ? ` A ${v.run_minutes}-minute run.` : ''}</p>
      <ol className="th-deck stack" data-testid="townhall-deck">{slides.map((s, i) => { const at = clock[i] ?? 0; return (
        <li key={s.key} className="pt-card ad-card stack" data-testid={`townhall-slide-${s.key}`}>
          <h2 className="d3">{i + 1}. {s.title}{s.admin_only ? <span className="ad-b ad-b--light"> Admin</span> : null}{s.minutes ? <span className="small muted" data-testid={`townhall-minutes-${s.key}`}> {at}:00 to {at + s.minutes}:00, {s.minutes} min</span> : null}</h2>
          {!!s.points.length && <dl className="th-points">{s.points.map((p) => <div key={p.label}><dt className="small muted">{p.label}</dt><dd className="d4">{p.value}</dd></div>)}</dl>}
          {!!s.lines?.length && <ul className="small">{s.lines.map((l) => <li key={l}>{l}</li>)}</ul>}
          {!!s.board?.length && <><p className="small"><b>Leaderboard</b></p><ol className="small">{s.board.map((p) => <li key={p.label}>{p.label}: {p.value}</li>)}</ol></>}
          {!!s.people?.length && <ul className="th-people" data-testid="townhall-people">{s.people.map((p) => (
            <li key={p.user_id} className="th-person" data-testid={`townhall-person-${p.user_id}`}>
              <p><b>{p.name}</b> <span className="small muted">{p.role}</span></p>
              {!!p.points?.length && <dl className="th-points">{p.points.map((x) => <div key={x.label}><dt className="small muted">{x.label}</dt><dd>{x.value}</dd></div>)}</dl>}
              {p.shoutout && <p className="small th-shout">{p.shoutout}</p>}
              {v.admin && <Act action="townhall_note" payload={{ deck: v.deck!.id, key: `p_${p.user_id}` }} label={p.shoutout ? 'Change the shout-out' : 'Add a shout-out'} refresh={refresh} done="Saved."
                fields={[{ name: 'note', label: `Shout-out for ${p.name}`, type: 'textarea', value: p.shoutout ?? '' }]} />}
            </li>))}</ul>}
          {s.note && <p className="small" data-testid={`townhall-note-${s.key}`}>{s.note}</p>}
          {v.admin && <Act action="townhall_note" payload={{ deck: v.deck!.id, key: s.key }} label={s.note ? 'Change the note' : 'Add a note'} refresh={refresh} done="Saved."
            fields={[{ name: 'note', label: 'What to say on this slide', type: 'textarea', value: s.note ?? '' }]} />}
        </li>); })}</ol>
    </>}
  </>);
}
