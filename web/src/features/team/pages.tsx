import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { door } from '@/server/door';
import { $, Card, PageHead, Table, label, t } from '@/features/admin/ui';
import { Scorecard, type Score } from '@/features/va/Scorecard';
import { academyWords, actionWords, hoursWords, owedCents, type TeamMember, type TeamRow } from './model';

// R51 (5302, REQ-131): My team, read only. A manager sees each staff member assigned to them: hours, academy progress,
// KPIs, pay owed, field jobs and activity, with the masking an Admin has (no pay details, no addresses, no customer numbers).
// The database refuses anyone who is not their manager.
export async function TeamPage({ userId, aal }: { userId: string; aal: 'aal1' | 'aal2' | null }) {
  const r = await door<{ members: TeamRow[] }>(userId, 'ops_read', 'my_team', {}, aal);
  return (
    <>
      <PageHead title="My team" kicker="Manager" purpose="The staff assigned to you, read only: hours in the last 7 days, academy, pay owed, field jobs and when they were last on. Open a person for their KPIs, jobs and activity." />
      <Card title={`Your team (${r.members.length})`} testId="team">
        <Table rows={r.members as unknown as Array<TeamRow & Record<string, unknown>>} testId="team-list" empty="Nobody is assigned to you yet. An Admin assigns staff on Settings > Staff." cols={[
          { key: 'name', label: 'Name', render: (m) => <Link prefetch={false} className="link" href={`/staff/team/${m.id}`} data-testid={`team-open-${m.id}`}>{m.name}</Link> },
          { key: 'functions', label: 'Works in', render: (m) => m.functions.map(label).join(', ') },
          { key: 'minutes_7d', label: 'Hours, 7 days', num: true, render: (m) => hoursWords(m.minutes_7d) },
          { key: 'academy', label: 'Academy', render: (m) => academyWords(m.academy) },
          { key: 'owed', label: 'Pay owed', num: true, render: (m) => <>{$(owedCents(m.pay))}{m.pay.held ? <span className="small muted"> (held: academy)</span> : null}</> },
          { key: 'jobs', label: 'Field jobs', num: true, render: (m) => `${m.jobs_open} open, ${m.jobs_done_7d} done` },
          { key: 'last_seen_at', label: 'Last on', render: (m) => t(m.last_seen_at) }]} />
      </Card>
    </>
  );
}

export async function TeamMemberPage({ userId, aal, id }: { userId: string; aal: 'aal1' | 'aal2' | null; id: string }) {
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const m = await door<TeamMember>(userId, 'ops_read', 'team_member', { user_id: id }, aal).catch((e: Error) => { if (/Not on your team|Only a manager/.test(e.message)) notFound(); throw e; });
  const score = m.scorecard as Score | null;
  return (
    <>
      <PageHead title={m.name} kicker={<><Link prefetch={false} className="link" href="/staff/team">My team</Link> · read only</>} purpose={m.functions.map(label).join(', ')} />
      <Card title="At a glance" testId="team-member-facts">
        <ul className="ad-list">
          <li><span>Hours, last 7 days</span><span className="num">{hoursWords(m.minutes_7d)}</span></li>
          <li><span>Academy</span><span>{academyWords(m.academy)}</span></li>
          <li><span>Pay owed (pay lines {$(m.pay.pay_lines_cents)}, commissions {$(m.pay.commission_cents)})</span><span className="num">{$(owedCents(m.pay))}{m.pay.held ? ' (held until the whole academy is passed)' : ''}</span></li>
          <li><span>Field jobs</span><span>{m.jobs_open} open, {m.jobs_done_7d} done in 7 days</span></li>
          <li><span>Last on</span><span>{t(m.last_seen_at) || 'Not yet'}</span></li>
        </ul>
      </Card>
      {score ? <Scorecard s={score} /> : <p className="ad-empty">No KPIs for this role yet.</p>}
      <Card title="Field jobs (last 14 days and next 7)" testId="team-member-jobs">
        <Table rows={m.jobs as unknown as Array<TeamMember['jobs'][number] & Record<string, unknown>>} testId="team-jobs" empty="No field jobs in this window." cols={[
          { key: 'at', label: 'When', render: (j) => t(j.at) }, { key: 'kind', label: 'Job', render: (j) => label(j.kind) }, { key: 'status', label: 'Status', render: (j) => label(j.status) },
          { key: 'booking', label: 'Booking', render: (j) => j.booking ?? '' }, { key: 'car', label: 'Car', render: (j) => j.car ?? '' }]} />
      </Card>
      <Card title="Hours (last 14 days)" testId="team-member-clock">
        <Table rows={m.clock as unknown as Array<TeamMember['clock'][number] & Record<string, unknown>>} testId="team-clock" empty="No hours in the last 14 days." cols={[
          { key: 'from', label: 'Started', render: (c) => t(c.from) }, { key: 'to', label: 'Ended', render: (c) => (c.to ? t(c.to) : 'Still on') },
          { key: 'kind', label: 'Kind', render: (c) => (c.kind === 'shift' ? 'Field shift' : 'Clocked in') }]} />
      </Card>
      <Card title="Activity (last 20 actions)" testId="team-member-activity">
        <Table rows={m.activity as unknown as Array<TeamMember['activity'][number] & Record<string, unknown>>} testId="team-activity" empty="No actions yet." sort={false} cols={[
          { key: 'at', label: 'When', render: (a) => t(a.at) }, { key: 'action', label: 'What', render: (a) => actionWords(a.action, a.what) }]} />
      </Card>
      <p className="small muted">Read only: a manager sees what an Admin sees of this person&apos;s work, and changes nothing here.</p>
    </>
  );
}
