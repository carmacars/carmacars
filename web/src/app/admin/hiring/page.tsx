import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, Card, Filters, PageHead, Table, Tabs, d } from '@/features/admin/ui';
import { CopyText } from '@/features/ads/CopyText';
import { applyPath, fmtSlot, inviteMessage, SOURCE_WORDS, STATUS_FILTERS, STATUS_WORDS } from '@/features/careers/model';
import { siteUrl } from '@/lib/site';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Hiring', path: '/admin/hiring', noindex: true, description: 'Applications from carmacars.ca/careers, interview days, the calls, the rubric and the ranked shortlist.' });
type R = Record<string, unknown>;
type Role = { id: string; slug: string; title: string; short_title: string; active: boolean; pass_mark: number; pay_text: string; remote: boolean; staff_kind: string; test_task: string | null; counts: Record<string, number>; total: number };
type App = { id: string; role: string; role_slug: string; status: string; full_name: string; email: string | null; phone: string | null; source: string; score: number | null; pass_mark: number;
  knockouts: string[]; created_at: string; slot_starts_at: string | null; mode: string | null; interview_score: number | null; final_score: number | null; decision: string | null; rank: number | null;
  referred_role: string | null; referred_from: string | null; referral_application: string | null; note: string | null };
type Day = { id: string; day: string; start_time: string; end_time: string; slot_minutes: number; buffer_minutes: number; capacity: number; mode: string; active: boolean; note: string | null; roles: string[]; role_slugs: string[]; slots: number; booked: number };
const tone = (s: string) => (['hired', 'interviewed', 'booked'].includes(s) ? 'published' : ['invited', 'below_bar', 'new'].includes(s) ? 'draft' : 'closed');

// Admin > People > Hiring (migration 0173): every application from carmacars.ca/careers with its screening score, the calls
// of a day with Start (the rubric beside the call guide), the ranked shortlist per role, the interview days, and the roles
// with their apply links for Indeed and OnlineJobs.ph. Only Admins see it.
export default async function Hiring({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/hiring'), searchParams]);
  const tab = sp.tab ?? 'pipeline';
  const base = '/admin/hiring';
  const data = await read<{ today: string; phone_enabled: boolean; roles: Role[]; applications: App[]; days: Day[] }>('hiring',
    { role: sp.role ?? '', status: sp.status ?? '', source: sp.source ?? '', min_score: sp.min_score ?? '' });
  const waiting = data.roles.reduce((n, r) => n + (r.counts.below_bar ?? 0), 0);
  const tabs = <Tabs current={`${base}?tab=${tab}`} items={[[`${base}?tab=pipeline`, 'Applications', waiting], [`${base}?tab=calls`, 'Calls'], [`${base}?tab=shortlist`, 'Shortlist'],
    [`${base}?tab=days`, 'Interview days'], [`${base}?tab=roles`, 'Roles and links']]} />;
  const head = <PageHead title="Hiring" kicker={`${data.roles.filter((r) => r.active).length} roles open`} purpose="Every applicant is scored on the server: a knock-out gets a decline (Field staff: an offer to apply for Sales), a pass gets a booking link, the rest wait here for you." />;
  const roleOptions: Array<[string, string]> = [['', 'All roles'], ...data.roles.map((r) => [r.slug, r.short_title] as [string, string])];

  if (tab === 'calls') {
    const s = await read<{ day: string; today: string; days: string[]; phone_enabled: boolean; free: number; calls: Array<App & { ends_at: string; meet_url: string | null }> }>('hiring_schedule', { day: sp.day ?? '' });
    return (<>{head}{tabs}
      <Filters base={`${base}?tab=calls`} name="day" value={s.day} sp={sp} options={(s.days.length ? s.days : [s.day]).map((x) => [x, `${d(x)}${x === s.today ? ' (today)' : ''}`] as [string, string])} />
      <Card title={`Calls on ${d(s.day)} (${s.calls.length})`} testId="hiring-calls" aside={<span className="small muted">{s.free} open slots left</span>}>
        <Table<App & R> rows={s.calls as Array<App & R>} rowKey={(x) => x.id} empty="No calls booked on this day." cols={[
          { key: 'slot_starts_at', label: 'Time (Toronto)', render: (x) => (x.slot_starts_at ? fmtSlot(x.slot_starts_at, undefined, false) : '') },
          { key: 'full_name', label: 'Candidate', render: (x) => <Link prefetch={false} className="link" href={`${base}/${x.id}`}>{x.full_name}</Link> },
          { key: 'role', label: 'Role' }, { key: 'score', label: 'Screening', num: true },
          { key: 'mode', label: 'How', render: (x) => (x.mode === 'video' ? (x.meet_url ? <a className="link" href={String(x.meet_url)} rel="noopener" target="_blank">Video link</a> : 'Video')
            : x.phone ? <a className="link" href={`tel:${String(x.phone).replace(/[^\d+]/g, '')}`}>{s.phone_enabled ? 'Call (Quo)' : 'Call'} {x.phone}</a> : 'Phone') },
          { key: 'status', label: 'Status', render: (x) => <Badge s={tone(x.status)}>{STATUS_WORDS[x.status] ?? x.status}</Badge> },
          { key: 'final_score', label: 'Final', num: true },
          { key: 'act', label: '', render: (x) => <Link prefetch={false} className="btn btn--primary btn--sm" href={`${base}/${x.id}#rubric`} data-testid={`start-${x.id}`}>{x.status === 'booked' ? 'Start' : 'Open'}</Link> }]} />
      </Card>
      <p className="small muted">Start opens the candidate with the rubric beside the call guide. Scores save as you go; the interview score, final score and rank fill in by themselves.</p></>);
  }
  if (tab === 'shortlist') {
    const s = await read<{ roles: Array<{ slug: string; title: string; rows: Array<App & R> }> }>('hiring_shortlist');
    return (<>{head}{tabs}
      {s.roles.length === 0 && <p className="muted" data-testid="hiring-shortlist-empty">No interviews scored yet. Score a call and it shows here, ranked.</p>}
      {s.roles.map((r) => (
        <Card key={r.slug} title={r.title} testId={`shortlist-${r.slug}`}>
          <Table<App & R> rows={r.rows} rowKey={(x) => x.id} cols={[
            { key: 'rank', label: 'Rank', num: true }, { key: 'full_name', label: 'Candidate', render: (x) => <Link prefetch={false} className="link" href={`${base}/${x.id}`}>{x.full_name}</Link> },
            { key: 'score', label: 'Screening', num: true }, { key: 'interview_score', label: 'Interview', num: true }, { key: 'final_score', label: 'Final (40/60)', num: true },
            { key: 'decision', label: 'Decision', render: (x) => (x.decision ? String(x.decision).replace('_', ' ') : '') },
            { key: 'status', label: 'Status', render: (x) => STATUS_WORDS[x.status] ?? x.status }]} />
        </Card>))}</>);
  }
  if (tab === 'days') {
    const dayFields = (v: Partial<Day> = {}) => [
      { name: 'day', label: 'Day', type: 'date' as const, required: true, value: v.day ?? data.today },
      { name: 'start_time', label: 'From (Toronto time, 24 h)', type: 'text' as const, required: true, value: v.start_time ?? '09:00', placeholder: '09:00' },
      { name: 'end_time', label: 'To (Toronto time, 24 h)', type: 'text' as const, required: true, value: v.end_time ?? '19:00', placeholder: '19:00' },
      { name: 'slot_minutes', label: 'Call length (minutes)', type: 'number' as const, min: 5, max: 120, value: v.slot_minutes ?? 15 },
      { name: 'buffer_minutes', label: 'Break between calls (minutes)', type: 'number' as const, min: 0, max: 60, value: v.buffer_minutes ?? 5 },
      { name: 'capacity', label: 'Candidates a slot', type: 'number' as const, min: 1, max: 10, value: v.capacity ?? 1 },
      { name: 'mode', label: 'How', type: 'select' as const, options: [['phone', 'Phone: we call the candidate'], ['video', 'Video: a Jitsi Meet link for each booking']] as Array<[string, string]>, value: v.mode ?? 'phone' },
      { name: 'roles', label: 'Roles (leave empty for every role)', type: 'list' as const, value: v.role_slugs ?? [], hint: `Role codes, separated by commas: ${data.roles.map((r) => r.slug).join(', ')}` },
      { name: 'note', label: 'Note (only Admins see it)', type: 'text' as const, value: v.note ?? '' }];
    return (<>{head}{tabs}
      <p className="row"><Act action="hiring_day_save" label="Add an interview day" variant="primary" testId="day-add" refresh={[base]} done="Day added with its slots." fields={dayFields()} /></p>
      <Card title="Interview days" testId="hiring-days">
        <Table<Day & R> rows={data.days as Array<Day & R>} rowKey={(x) => x.id} empty="No interview day yet. Add one: candidates who pass are invited to book on it." cols={[
          { key: 'day', label: 'Day', render: (x) => d(x.day) }, { key: 'start_time', label: 'Hours', render: (x) => `${x.start_time} to ${x.end_time}` },
          { key: 'slot_minutes', label: 'Slots', render: (x) => `${x.slot_minutes} min + ${x.buffer_minutes} min break` },
          { key: 'mode', label: 'How', render: (x) => (x.mode === 'video' ? 'Video' : 'Phone') }, { key: 'roles', label: 'Roles', className: 'wrap', render: (x) => x.roles.join(', ') },
          { key: 'booked', label: 'Booked', num: true, render: (x) => `${x.booked} of ${x.slots * x.capacity}` },
          { key: 'active', label: 'Open', render: (x) => (x.active ? 'Yes' : 'Off') },
          { key: 'act', label: '', render: (x) => <span className="ad-actions">
            <Act action="hiring_day_save" payload={{ id: x.id }} label="Change" refresh={[base]} done="Saved." fields={dayFields(x)} />
            <Act action="hiring_day_save" payload={{ id: x.id, active: !x.active }} label={x.active ? 'Turn off' : 'Turn on'} refresh={[base]} done="Saved." />
            {x.booked === 0 && <Act action="hiring_day_delete" payload={{ id: x.id }} label="Delete" variant="danger" refresh={[base]} done="Deleted." confirm="Delete this day and its slots?" />}</span> }]} />
      </Card></>);
  }
  if (tab === 'roles') {
    const site = siteUrl();
    return (<>{head}{tabs}
      {data.roles.map((r) => {
        const src = r.remote ? 'onlinejobs' : 'indeed';
        const link = site + applyPath(r.slug, src);
        const otherSrc = src === 'indeed' ? 'onlinejobs' : 'indeed';
        return (
          <Card key={r.slug} title={r.title} testId={`role-card-${r.slug}`} aside={<Badge s={r.active ? 'published' : 'closed'}>{r.active ? 'Open' : 'Closed'}</Badge>}>
            <p className="small muted">{r.pay_text}. Pass mark {r.pass_mark} of 100. {r.total} applications.</p>
            <p className="row">
              <Act action="hiring_role_save" payload={{ slug: r.slug, active: !r.active }} label={r.active ? 'Close the role' : 'Open the role'} variant={r.active ? 'ghost' : 'primary'} testId={`role-toggle-${r.slug}`}
                refresh={[base, '/careers', `/careers/${r.slug}`, '/sitemap.xml', '/']} done={r.active ? 'Closed: off the careers page.' : 'Open: on the careers page.'} />
              <Act action="hiring_role_save" payload={{ slug: r.slug }} label="Pass mark and pay" refresh={[base, '/careers', `/careers/${r.slug}`]} done="Saved."
                fields={[{ name: 'pass_mark', label: 'Pass mark (0 to 100)', type: 'number', min: 0, max: 100, value: r.pass_mark }, { name: 'pay_text', label: 'Pay, as shown on the page', type: 'text', value: r.pay_text }]} />
              {r.active && <Link prefetch={false} className="link" href={`/careers/${r.slug}`}>Public page</Link>}
            </p>
            <CopyText label={src === 'indeed' ? 'Indeed apply link' : 'OnlineJobs.ph apply link'} value={link} testId={`link-${r.slug}`} />
            <CopyText label={src === 'indeed' ? 'Indeed message' : 'OnlineJobs.ph message'} value={inviteMessage(r.title, link)} rows={4} testId={`msg-${r.slug}`} />
            <CopyText label={otherSrc === 'indeed' ? 'Indeed apply link' : 'OnlineJobs.ph apply link'} value={site + applyPath(r.slug, otherSrc)} testId={`link2-${r.slug}`} />
          </Card>);
      })}</>);
  }
  return (<>{head}{tabs}
    <div className="row" style={{ gap: '1rem', flexWrap: 'wrap' }}>
      <Filters base={`${base}?tab=pipeline`} name="role" value={sp.role ?? ''} sp={sp} options={roleOptions} />
      <Filters base={`${base}?tab=pipeline`} name="status" value={sp.status ?? ''} sp={sp} options={STATUS_FILTERS} />
      <Filters base={`${base}?tab=pipeline`} name="source" value={sp.source ?? ''} sp={sp} options={[['', 'Any source'], ...Object.entries(SOURCE_WORDS)]} />
      <Filters base={`${base}?tab=pipeline`} name="min_score" value={sp.min_score ?? ''} sp={sp} options={[['', 'Any score'], ['60', '60 or more'], ['75', '75 or more'], ['90', '90 or more']]} />
    </div>
    <Card title={`Applications (${data.applications.length})`} testId="hiring-apps">
      <Table<App & R> rows={data.applications as Array<App & R>} rowKey={(x) => x.id} empty="No applications match. Paste the apply link of a role into Indeed messages (Roles and links)." cols={[
        { key: 'full_name', label: 'Candidate', render: (x) => <span><Link prefetch={false} className="link" href={`${base}/${x.id}`} data-testid={`app-${x.email ?? x.id}`}>{x.full_name}</Link>
          {x.referred_from && <span className="cr-sub">Referred from another role</span>}{x.referral_application && <span className="cr-sub">Applied for {x.referred_role} too</span>}</span> },
        { key: 'role', label: 'Role' },
        { key: 'score', label: 'Score', num: true, render: (x) => (x.score === null ? '' : <b className={x.score >= x.pass_mark ? '' : 'muted'}>{x.score}</b>) },
        { key: 'status', label: 'Status', className: 'wrap', render: (x) => <span><Badge s={tone(x.status)}>{STATUS_WORDS[x.status] ?? x.status}</Badge>
          {x.status === 'referred' && x.referred_role && <span className="cr-sub">to {x.referred_role}</span>}{x.knockouts.length > 0 && <span className="cr-sub">{x.knockouts.length} knock-out</span>}</span> },
        { key: 'slot_starts_at', label: 'Call', render: (x) => (x.slot_starts_at && x.status === 'booked' ? fmtSlot(x.slot_starts_at) : '') },
        { key: 'final_score', label: 'Final', num: true }, { key: 'rank', label: 'Rank', num: true },
        { key: 'source', label: 'Source', render: (x) => SOURCE_WORDS[x.source] ?? x.source }, { key: 'created_at', label: 'Applied', render: (x) => d(x.created_at) },
        { key: 'act', label: '', render: (x) => <span className="ad-actions">
          {['below_bar', 'declined', 'referred', 'no_show'].includes(x.status) && <Act action="hiring_invite" payload={{ id: x.id }} label="Invite anyway" refresh={[base]} done="Invited: the booking link is on its way." confirm={`Send ${x.full_name} the booking link?`} />}
          {['below_bar', 'invited', 'referred', 'no_show'].includes(x.status) && <Act action="hiring_decline" payload={{ id: x.id }} label="Decline" refresh={[base]} done="Declined."
            fields={[{ name: 'email', label: 'Send the polite decline email', type: 'bool', value: true }, { name: 'reason', label: 'The requirement it names (optional: "This role needs ...")', type: 'text' }]} />}</span> }]} />
    </Card></>);
}
