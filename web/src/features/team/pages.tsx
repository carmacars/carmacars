import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { door } from '@/server/door';
import { $, Card, PageHead, Table, label, t } from '@/features/admin/ui';
import { Scorecard, type Score } from '@/features/va/Scorecard';
import { FOLLOWUP_LABEL, academyWords, actionWords, hoursWords, owedCents, type Followup, type TeamMember, type TeamRow } from './model';
import { ContactButtons } from '@/features/phone/QuoButtons';
import { Act } from '@/features/admin/Act';

// R51 (5201, REQ-131): My team, read only. A manager sees each staff member assigned to them: hours, academy progress,
// KPIs, pay owed, field jobs and activity, with the masking an Admin has (no pay details, no addresses, no customer numbers).
// The database refuses anyone who is not their manager.
export async function TeamPage({ userId, aal }: { userId: string; aal: 'aal1' | 'aal2' | null }) {
  const r = await door<{ members: TeamRow[]; followups: Followup[]; followups_waiting: number; manager_passed: boolean; manager_section: string }>(userId, 'ops_read', 'my_team', {}, aal);
  return (
    <>
      <PageHead title="My team" kicker="Manager" purpose="The staff assigned to you, read only: hours in the last 7 days, academy, pay owed, field jobs and when they were last on. Open a person for their KPIs, jobs and activity." />
      {/* 5206 (REQ-138): the follow-ups, after the Manager section of the academy is passed */}
      <Card title={`Follow up (${r.followups_waiting})`} testId="team-followups" tone={r.followups_waiting ? 'next' : undefined}>
        {!r.manager_passed ? <div className="alert alert--warn stack" role="status" data-testid="team-followups-locked"><span className="alert__title">Pass the Manager section first</span>
            <span>{r.followups_waiting ? `${r.followups_waiting} follow-up${r.followups_waiting === 1 ? ' is' : 's are'} waiting. ` : ''}The academy&apos;s Manager section teaches how to follow up, coach, escalate and check hours. Pass it to open your follow-ups.</span>
            <p><Link prefetch={false} className="btn btn--primary" href={r.manager_section} data-testid="team-manager-section">Open the Manager section</Link></p></div>
          : r.followups.length === 0 ? <p className="ad-empty">Nothing to follow up. New ones come when someone stalls in the academy, has onboarding steps open, misses a shift or a job, or was below a KPI target last week.</p>
          : <ul className="ad-list" data-testid="team-followup-list">{r.followups.map((f) => (
            <li key={f.id} className="stack" data-testid={`team-followup-${f.id}`}>
              <span><b>{f.name}</b> · {FOLLOWUP_LABEL[f.kind]}{f.overdue ? <span className="ad-flag ad-flag--red"> Overdue: sent to the Admins</span> : <span className="small muted"> · due {t(f.due_at)}</span>}</span>
              <span className="small">{f.detail}</span>
              <span className="ad-actions">
                <ContactButtons phone={f.phone} name={f.name} testId={`team-followup-contact-${f.id}`} />
                <Act ops action="team_followup_done" payload={{ id: f.id }} label="Mark followed up" variant="primary" title={`Followed up with ${f.name}`} submitLabel="Save" refresh={['/staff/team']} done="Followed up."
                  testId={`team-followup-done-${f.id}`} fields={[{ name: 'note', label: 'What you agreed', type: 'textarea', required: true, placeholder: 'For example: two sections by Friday' }]} />
              </span>
            </li>))}</ul>}
      </Card>
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
