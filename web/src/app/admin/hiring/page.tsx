import Link from '@/components/Link';
import { door } from '@/server/door';
import { OnboardingPipeline } from '@/features/staff-onboarding/Pipeline';
import type { ApprovalRow, OnboardingRow } from '@/features/staff-onboarding/model';
import type { StaffAgreementRow } from '@/features/manual/StaffAgreements';
import { ListFilters } from '@/features/list-filters/ListFilters';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { DecisionEmails, type DecisionsData } from '@/features/careers/admin/DecisionEmails';
import { FieldCallsCard, type FieldCall } from '@/features/field-portal/FieldCalls';
import { Badge, Card, Filters, Kv, PageHead, Table, Tabs, d, t } from '@/features/admin/ui';
import { CopyText } from '@/features/ads/CopyText';
import { applyPath, DECISIONS, fmtSlot, inviteMessage, SOURCE_WORDS, STATUS_FILTERS, STATUS_WORDS } from '@/features/careers/model';
import { siteUrl } from '@/lib/site';
import { AI_STATE_WORDS, RECOMMENDATION_WORDS, type InterviewState, type Recommendation } from '@/features/careers/ai-interview';
import { ContactButtons } from '@/features/phone/QuoButtons';
import { MeetCard, type MeetState } from '@/features/meet/MeetCard';

// 2590: what the AI interviews decided by themselves this week
const AI_WEEK: Array<[string, string]> = [['hire', 'hired'], ['live_call', 'live call'], ['sales', 'to Sales'], ['decline', 'declined'], ['failed', 'failed']];
const aiWeek = (w?: Record<string, number>) => AI_WEEK
  .filter(([k]) => (w?.[k] ?? 0) > 0).map(([k, l]) => `${w![k]} ${l}`).join(', ') || 'none';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Hiring', path: '/admin/hiring', noindex: true, description: 'Applications from carmacars.ca/careers, interview days, the calls, the rubric and the ranked shortlist.' });
type R = Record<string, unknown>;
type Role = { id: string; slug: string; title: string; short_title: string; active: boolean; pass_mark: number; pay_text: string; remote: boolean; staff_kind: string; test_task: string | null; counts: Record<string, number>; total: number };
type App = { id: string; role: string; role_slug: string; status: string; full_name: string; email: string | null; phone: string | null; source: string; score: number | null; pass_mark: number;
  knockouts: string[]; created_at: string; location?: string | null; location_area?: string | null; location_mismatch?: boolean; move_remote?: boolean; phone_country?: string | null; ip_country?: string | null; slot_starts_at: string | null; mode: string | null; interview_score: number | null; final_score: number | null; decision: string | null; rank: number | null;
  referred_role: string | null; referred_from: string | null; referral_application: string | null; note: string | null;
  ai?: { state: InterviewState; recommendation: Recommendation | null; score: number | null; live_call?: boolean } | null };
type Day = { id: string; day: string; start_time: string; end_time: string; slot_minutes: number; buffer_minutes: number; capacity: number; mode: string; active: boolean; note: string | null; roles: string[]; role_slugs: string[]; slots: number; booked: number };
const CONFIRM_WORDS: Record<string, string> = { confirmed: 'Confirmed', waiting: 'Waiting', not_asked: 'Asked 24 hours before', cancelled: 'Cancelled' };
const tone = (s: string) => (['hired', 'interviewed', 'booked'].includes(s) ? 'published' : ['invited', 'below_bar', 'new'].includes(s) ? 'draft' : 'closed');

// Admin > People > Hiring (migration 0173): every application from carmacars.ca/careers with its screening score, the calls
// of a day with Start (the rubric beside the call guide), the ranked shortlist per role, the interview days, and the roles
// with their apply links for Indeed and OnlineJobs.ph. Only Admins see it.
export default async function Hiring({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, user }, sp] = await Promise.all([page('/admin/hiring'), searchParams]);
  const tab = sp.tab ?? 'pipeline';
  const base = '/admin/hiring';
  const data = await read<{ today: string; phone_enabled: boolean; roles: Role[]; applications: App[]; days: Day[]; waiting?: Array<{ slug: string; title: string; count: number }>; decisions_waiting?: number;
    ai_interviews?: { enabled: boolean; days: number; followups: number; waiting: number; answer_seconds?: number; retakes?: number; video_days?: number;
      /** 2590 */ pass_mark?: number; auto_decide?: boolean; week?: Record<string, number> } }>('hiring',
    { role: sp.role ?? '', status: sp.status ?? '', source: sp.source ?? '', min_score: sp.min_score ?? '' });
  const waiting = data.roles.reduce((n, r) => n + (r.counts.below_bar ?? 0), 0);
  const tabs = <Tabs current={`${base}?tab=${tab}`} items={[[`${base}?tab=stages`, 'Pipeline'], [`${base}?tab=pipeline`, 'Applications', waiting], [`${base}?tab=calls`, 'Calls'], [`${base}?tab=shortlist`, 'Shortlist'],
    [`${base}?tab=days`, 'Interview days'], [`${base}?tab=roles`, 'Roles and links'], [`${base}?tab=emails`, 'Emails to send', data.decisions_waiting ?? 0]]} />;
  const pageHead = <PageHead title="Hiring" kicker={`${data.roles.filter((r) => r.active).length} roles open`} purpose="Every applicant is scored on the server: a knock-out gets a decline (Field staff: an offer to apply for Sales), a pass gets a booking link (remote assistants: an AI interview), the rest wait here for you." />;
  // r37 (2303): video calls on Google Meet once the company calendar is connected, else Jitsi
  const meet = await read<MeetState>('calendar_google_state').catch(() => null);
  const head = <>{pageHead}<MeetCard s={meet} flash={sp.calendar} /></>;
  // 0211: per role, applicants invited while no interview day is open (their invitation, or "New times are open", goes when a day is added)
  const noDay = (data.waiting ?? []).map((w) => (
    <p key={w.slug} className="alert alert--warn" role="status" data-testid={`hiring-no-day-${w.slug}`}><span>{w.count} applicant{w.count === 1 ? '' : 's'} invited but no interview day is open for {w.title}. <Link prefetch={false} className="link" href={`${base}?tab=days`}>Add an interview day</Link></span></p>));
  // r43: one pipeline, one stage per person: Applied > AI interview > Interview booked > Decision > Agreement > Academy > WhatsApp > Approval > Onboarded
  if (tab === 'stages') {
    const [staff, approvals, agreements] = await Promise.all([
      door<OnboardingRow[]>(user.id, 'ops_read', 'staff_onboarding_list', {}).catch(() => [] as OnboardingRow[]),
      door<ApprovalRow[]>(user.id, 'ops_read', 'staff_onboarding_approvals', {}).catch(() => [] as ApprovalRow[]),
      door<StaffAgreementRow[]>(user.id, 'ops_read', 'staff_agreements', {}).catch(() => [] as StaffAgreementRow[])]);
    return (<>{head}{noDay}{tabs}
      <OnboardingPipeline admin refresh={[base + '?tab=stages', '/admin/settings/staff']} apps={data.applications} staff={staff} approvals={approvals} agreements={agreements} />
      <p className="small muted">Staff agreements for everyone, the limits and the functions are on <Link prefetch={false} className="link" href="/admin/settings/staff">Staff and roles</Link>.</p></>);
  }
  // R23 (0226): the decisions of the calls and the emails they send, all at once
  if (tab === 'emails') return (<>{head}{tabs}<DecisionEmails d={await read<DecisionsData>('hiring_decisions')} /></>);

  if (tab === 'calls') {
    const s = await read<{ day: string; today: string; days: string[]; phone_enabled: boolean; free: number; calls: Array<App & { ends_at: string; meet_url: string | null; confirm?: string | null }>;
      unconfirmed?: Array<{ id: string; full_name: string; role: string; cancelled_at: string }> }>('hiring_schedule', { day: sp.day ?? '' });
    const fieldCalls = await read<FieldCall[]>('field_call_slots').catch(() => [] as FieldCall[]);
    return (<>{head}{noDay}{tabs}
      {fieldCalls.length > 0 && <FieldCallsCard calls={fieldCalls} />}
      <Filters base={`${base}?tab=calls`} name="day" value={s.day} sp={sp} options={(s.days.length ? s.days : [s.day]).map((x) => [x, `${d(x)}${x === s.today ? ' (today)' : ''}`] as [string, string])} />
      <Card title={`Calls on ${d(s.day)} (${s.calls.length})`} testId="hiring-calls" aside={<span className="small muted">{s.free} open slots left</span>}>
        <Table<App & R> rows={s.calls as Array<App & R>} rowKey={(x) => x.id} empty="No calls booked on this day." cols={[
          { key: 'slot_starts_at', label: 'Time (Toronto)', render: (x) => (x.slot_starts_at ? fmtSlot(x.slot_starts_at, undefined, false) : '') },
          { key: 'full_name', label: 'Candidate', render: (x) => <Link prefetch={false} className="link" href={`${base}/${x.id}`}>{x.full_name}</Link> },
          { key: 'role', label: 'Role' }, { key: 'score', label: 'Screen', num: true },
          { key: 'mode', label: 'How', render: (x) => (x.mode === 'video' ? (x.meet_url ? <a className="link" href={String(x.meet_url)} rel="noopener" target="_blank">Video link</a> : 'Video')
            : x.phone ? <ContactButtons phone={String(x.phone)} name={x.full_name ? String(x.full_name) : null} only="call" look="link" testId="hire-call">Call {String(x.phone)}</ContactButtons> : 'Phone') },
          // 0229: a remote role's call is confirmed by the candidate (24 hours before), or cancelled; shown under the status
          // (its own column pushed the table past the screen)
          { key: 'status', label: 'Status', render: (x) => <><Badge s={tone(x.status)}>{STATUS_WORDS[x.status] ?? x.status}</Badge>{CONFIRM_WORDS[String(x.confirm ?? '')] ? <span className="small muted" style={{ display: 'block' }} data-testid={`call-confirm-${x.id}`}>{CONFIRM_WORDS[String(x.confirm ?? '')]}</span> : null}</> },
          { key: 'final_score', label: 'Final', num: true },
          { key: 'act', label: '', render: (x) => <Link prefetch={false} className="btn btn--primary btn--sm" href={`${base}/${x.id}#rubric`} data-testid={`start-${x.id}`}>{x.status === 'booked' ? 'Start' : 'Open'}</Link> }]} />
      </Card>
      {(s.unconfirmed ?? []).length > 0 && <Card title="Cancelled: not confirmed" testId="hiring-unconfirmed">
        <ul className="small">{s.unconfirmed!.map((u) => <li key={u.id}><Link prefetch={false} className="link" href={`${base}/${u.id}`}>{u.full_name}</Link> ({u.role}), {t(u.cancelled_at)}: they can book again from their link.</li>)}</ul>
      </Card>}
      <p className="small muted">The in-person roles are called by phone and the remote roles meet by video, whatever the day says. A remote candidate confirms the call from an email 24 hours before; unconfirmed calls are cancelled.</p>
      <p className="small muted">Start opens the candidate with the rubric beside the call guide. Scores save as you go; the interview score, final score and rank fill in by themselves.</p></>);
  }
  if (tab === 'shortlist') {
    const s = await read<{ roles: Array<{ slug: string; title: string; rows: Array<App & R> }> }>('hiring_shortlist');
    return (<>{head}{noDay}{tabs}
      {s.roles.length === 0 && <p className="muted" data-testid="hiring-shortlist-empty">No interviews scored yet. Score a call and it shows here, ranked.</p>}
      {s.roles.map((r) => (
        <Card key={r.slug} title={r.title} testId={`shortlist-${r.slug}`}>
          <Table<App & R> sort={false} rows={r.rows} rowKey={(x) => x.id} cols={[
            { key: 'rank', label: 'Rank', num: true }, { key: 'full_name', label: 'Candidate', render: (x) => <Link prefetch={false} className="link" href={`${base}/${x.id}`}>{x.full_name}</Link> },
            { key: 'score', label: 'Screening', num: true }, { key: 'interview_score', label: 'Interview', num: true }, { key: 'final_score', label: 'Final (40/60)', num: true },
            { key: 'decision', label: 'Decision', render: (x) => (x.decision ? (DECISIONS.find(([k]) => k === x.decision)?.[1] ?? String(x.decision).replace('_', ' ')) : '') },
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
      { name: 'mode', label: 'How (the default shown; each call follows its role: in person by phone, remote by video)', type: 'select' as const, options: [['phone', 'Phone: we call the candidate'], ['video', 'Video: a Jitsi Meet link for each booking']] as Array<[string, string]>, value: v.mode ?? 'phone' },
      { name: 'roles', label: 'Roles (leave empty for every role)', type: 'list' as const, value: v.role_slugs ?? [], hint: `Role codes, separated by commas: ${data.roles.map((r) => r.slug).join(', ')}` },
      { name: 'note', label: 'Note (only Admins see it)', type: 'text' as const, value: v.note ?? '' }];
    return (<>{head}{noDay}{tabs}
      <div className="row"><Act action="hiring_day_save" label="Add an interview day" variant="primary" testId="day-add" refresh={[base]} done="Day added with its slots." fields={dayFields()} /></div>
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
    const ai = data.ai_interviews;
    return (<>{head}{noDay}{tabs}
      {ai && <Card title="AI interviews for the remote roles" testId="hiring-ai-setting" aside={<Badge s={ai.enabled ? 'published' : 'closed'}>{ai.enabled ? 'On' : 'Off'}</Badge>}>
        <p className="small">{ai.enabled
          ? `Every applicant who passes screening takes an interview answered on video only (nothing is typed), the pre-screen to the academy: ${ai.days} days to take it, up to ${ai.followups} probing follow-up questions. ${ai.auto_decide === false ? 'The AI scores it and recommends; you decide.' : `It decides by itself: ${ai.pass_mark ?? 80} of 100 or more with no knock-out answer passes: instant hire is for Sales only (hired by itself); every other role is invited to book an interview date, the one step that needs you; under it, the decline or Sales email goes. You are told, never asked.`}`
          : 'Off: remote assistants who pass screening get the link to book a live call, as the in-person roles do.'}</p>
        <Kv rows={[['Answer time', `${(ai.answer_seconds ?? 120) / 60} minute${(ai.answer_seconds ?? 120) === 60 ? '' : 's'} for each answer`],
          ['Retakes allowed', String(ai.retakes ?? 0)], ['Keep interview videos', `${ai.video_days ?? 90} days, then deleted`],
          ['The bar to pass', `${ai.pass_mark ?? 80} of 100`], ['Decided in the last 7 days', aiWeek(ai.week)]]} />
        <div className="row"><Act action="hiring_ai_settings" payload={{ enabled: !ai.enabled }} label={ai.enabled ? 'Turn off' : 'Turn on'} variant={ai.enabled ? 'ghost' : 'primary'} testId="hiring-ai-toggle"
          refresh={[base]} done={ai.enabled ? 'AI interviews are off.' : 'AI interviews are on.'} />
          <Act action="hiring_ai_settings" payload={{}} label="Interview settings" testId="hiring-ai-settings" refresh={[base]} done="Saved."
            fields={[{ name: 'answer_minutes', label: 'Answer time (minutes, 1 to 3)', type: 'number', min: 1, max: 3, value: (ai.answer_seconds ?? 120) / 60, required: true },
              { name: 'retakes', label: 'Retakes allowed (0 to 3)', type: 'number', min: 0, max: 3, value: ai.retakes ?? 0, required: true },
              { name: 'video_days', label: 'Keep interview videos (days)', type: 'number', min: 1, max: 365, value: ai.video_days ?? 90, required: true },
              { name: 'pass_mark', label: 'The bar to pass (50 to 100)', type: 'number', min: 50, max: 100, value: ai.pass_mark ?? 80, required: true },
              { name: 'followups', label: 'Follow-up questions (0 to 6)', type: 'number', min: 0, max: 6, value: ai.followups, required: true }]} />
          <Act action="hiring_ai_settings" payload={{ auto_decide: ai.auto_decide === false }} label={ai.auto_decide === false ? 'Decide automatically' : 'Decide by hand'} variant="ghost" testId="hiring-ai-auto"
            refresh={[base]} done="Saved." /></div>
      </Card>}
      {data.roles.map((r) => {
        const src = r.remote ? 'onlinejobs' : 'indeed';
        const link = site + applyPath(r.slug, src);
        const otherSrc = src === 'indeed' ? 'onlinejobs' : 'indeed';
        return (
          <Card key={r.slug} title={r.title} testId={`role-card-${r.slug}`} aside={<Badge s={r.active ? 'published' : 'closed'}>{r.active ? 'Open' : 'Closed'}</Badge>}>
            <p className="small muted">{r.pay_text}. Pass mark {r.pass_mark} of 100. {r.total} applications.</p>
            <div className="row">
              <Act action="hiring_role_save" payload={{ slug: r.slug, active: !r.active }} label={r.active ? 'Close the role' : 'Open the role'} variant={r.active ? 'ghost' : 'primary'} testId={`role-toggle-${r.slug}`}
                refresh={[base, '/careers', `/careers/${r.slug}`, '/sitemap.xml', '/']} done={r.active ? 'Closed: off the careers page.' : 'Open: on the careers page.'} />
              <Act action="hiring_role_save" payload={{ slug: r.slug }} label="Pass mark and pay" refresh={[base, '/careers', `/careers/${r.slug}`]} done="Saved."
                fields={[{ name: 'pass_mark', label: 'Pass mark (0 to 100)', type: 'number', min: 0, max: 100, value: r.pass_mark }, { name: 'pay_text', label: 'Pay, as shown on the page', type: 'text', value: r.pay_text }]} />
              {r.active && <Link prefetch={false} className="link" href={`/careers/${r.slug}`}>Public page</Link>}
            </div>
            <CopyText label={src === 'indeed' ? 'Indeed apply link' : 'OnlineJobs.ph apply link'} value={link} testId={`link-${r.slug}`} />
            <CopyText label={src === 'indeed' ? 'Indeed message' : 'OnlineJobs.ph message'} value={inviteMessage(r.title, link)} rows={4} testId={`msg-${r.slug}`} />
            <CopyText label={otherSrc === 'indeed' ? 'Indeed apply link' : 'OnlineJobs.ph apply link'} value={site + applyPath(r.slug, otherSrc)} testId={`link2-${r.slug}`} />
          </Card>);
      })}</>);
  }
  const aiWaiting = data.ai_interviews?.waiting ?? 0;
  return (<>{head}{noDay}{tabs}
    {aiWaiting > 0 && <p className="alert" role="status" data-testid="hiring-ai-waiting"><span>{aiWaiting} AI interview{aiWaiting === 1 ? '' : 's'} done and waiting for your decision (automatic decisions are off in Interview settings). <Link prefetch={false} className="link" href={`${base}?tab=pipeline&status=interviewed`}>Show interviewed</Link></span></p>}
    <ListFilters id="admin-hiring" base={`${base}?tab=pipeline`} sp={sp} chips={{ name: 'status', label: 'Status', options: STATUS_FILTERS.filter(([v]) => ['', 'open', 'invited', 'booked', 'interviewed'].includes(v)) }}
      kept={['role', 'source', 'min_score']} />
    <Card title={`Applications (${data.applications.length})`} testId="hiring-apps">
      <Table<App & R> defaultSort="newest" rows={data.applications as Array<App & R>} rowKey={(x) => x.id} empty="No applications match. Paste the apply link of a role into Indeed messages (Roles and links)." cols={[
        { key: 'full_name', label: 'Candidate', render: (x) => <span><Link prefetch={false} className="link" href={`${base}/${x.id}`} data-testid={`app-${x.email ?? x.id}`}>{x.full_name}</Link>
          {x.referred_from && <span className="cr-sub">Referred from another role</span>}{x.referral_application && <span className="cr-sub">Applied for {x.referred_role} too</span>}</span> },
        { key: 'role', label: 'Role' },
        { key: 'location', label: 'Lives in', className: 'wrap', render: (x) => <span>{x.location ?? ''}{x.location_area === 'outside' && <span className="cr-sub">outside the area</span>}
          {x.location_mismatch && <span className="cr-sub" data-testid={`app-mismatch-${x.id}`}><Badge s="needs_review">Location mismatch</Badge></span>}</span> },
        { key: 'score', label: 'Score', num: true, render: (x) => (x.score === null ? '' : <b className={x.score >= x.pass_mark ? '' : 'muted'}>{x.score}</b>) },
        { key: 'status', label: 'Status', className: 'wrap', render: (x) => <span><Badge s={tone(x.status)}>{STATUS_WORDS[x.status] ?? x.status}</Badge>
          {x.ai && !x.ai.live_call && <span className="cr-sub" data-testid={`app-ai-${x.id}`}>{AI_STATE_WORDS[x.ai.state]}{x.ai.recommendation ? `: ${RECOMMENDATION_WORDS[x.ai.recommendation]}` : ''}</span>}
          {x.status === 'referred' && x.referred_role && <span className="cr-sub">to {x.referred_role}</span>}{x.knockouts.length > 0 && <span className="cr-sub">{x.knockouts.length} knock-out</span>}</span> },
        { key: 'slot_starts_at', label: 'Call', render: (x) => (x.slot_starts_at && x.status === 'booked' ? fmtSlot(x.slot_starts_at) : '') },
        { key: 'final_score', label: 'Final', num: true }, { key: 'rank', label: 'Rank', num: true },
        { key: 'source', label: 'Source', render: (x) => SOURCE_WORDS[x.source] ?? x.source }, { key: 'created_at', label: 'Applied', render: (x) => d(x.created_at) },
        { key: 'act', label: '', render: (x) => <span className="ad-actions">
          {x.move_remote && <Act action="hiring_move_remote" payload={{ id: x.id }} label="Move to Remote Sales" refresh={[base]} done="Moved: they have the Remote Sales link with their details." confirm={`Send ${x.full_name} to Remote Sales (in person needs the Toronto area)?`} testId={`app-move-${x.id}`} />}
          {['below_bar', 'declined', 'referred', 'no_show'].includes(x.status) && <Act action="hiring_invite" payload={{ id: x.id }} label="Invite anyway" refresh={[base]} done="Invited: the booking link is on its way." confirm={`Send ${x.full_name} the booking link?`} />}
          {['below_bar', 'invited', 'referred', 'no_show'].includes(x.status) && <Act action="hiring_decline" payload={{ id: x.id }} label="Decline" refresh={[base]} done="Declined."
            fields={[{ name: 'email', label: 'Send the polite decline email', type: 'bool', value: true }, { name: 'reason', label: 'The requirement it names (optional: "This role needs ...")', type: 'text' }]} />}</span> }]} />
    </Card></>);
}
