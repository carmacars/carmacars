import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { SendGenerated } from '@/features/manual/SignRequests';
import type { StaffAgreementRow } from '@/features/manual/StaffAgreements';
import { OnboardingApprovals } from './Approvals';
import { groupPipeline, STAGES, type PipeApp, type Stage } from './pipeline';
import { markable, waitingWords, type ApprovalRow, type OnboardingRow } from './model';

const day = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', month: 'short', day: 'numeric' }).format(new Date(`${iso.slice(0, 10)}T12:00:00Z`));

// r43: Admin > People > Hiring > Pipeline, and the Fleet portal. One section per stage, in order; each person in exactly one
// stage, with the one next action for that stage on their line. The counts on top jump to the stage. The Fleet portal
// passes no applications and no agreements (staff only).
export function OnboardingPipeline({ apps = [], staff, approvals, agreements, admin, refresh, hiringBase = '/admin/hiring' }: {
  apps?: PipeApp[]; staff: OnboardingRow[]; approvals: ApprovalRow[]; agreements?: StaffAgreementRow[]; admin?: boolean; refresh: string[]; hiringBase?: string;
}) {
  const g = groupPipeline(apps, staff);
  const agr = new Map((agreements ?? []).map((a) => [a.user_id, a]));
  const waiting = new Map(approvals.map((a) => [a.user_id, a]));
  const shown = STAGES.filter((s) => apps.length || !['applied', 'ai', 'booked', 'decision'].includes(s.key));
  const link = (id: string, text: string, hash = '') => <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${hiringBase}/${id}${hash}`}>{text}</Link>;

  const appRow = (a: PipeApp, stage: Stage) => (
    <li key={a.id} data-testid={`pipeline-app-${a.id}`}>
      <span><b>{a.full_name}</b> ({a.role}){a.score !== null ? `, screening ${a.score}` : ''}, applied {day(a.created_at)}</span>
      <span className="ad-actions">
        {stage === 'applied' && a.status === 'below_bar' && admin && <Act action="hiring_invite" payload={{ id: a.id }} label="Invite anyway" refresh={refresh} done="Invited: the booking link is on its way." />}
        {stage === 'applied' && admin && <Act action="hiring_decline" payload={{ id: a.id }} label="Decline" refresh={refresh} done="Declined."
          fields={[{ name: 'email', label: 'Send the polite decline email', type: 'bool', value: true }, { name: 'reason', label: 'The requirement it names (optional)', type: 'text' }]} />}
        {stage === 'applied' && !admin && link(a.id, 'Open')}
        {stage === 'ai' && link(a.id, 'Open')}
        {stage === 'booked' && link(a.id, a.status === 'booked' ? 'Start the call' : 'Open', a.status === 'booked' ? '#rubric' : '')}
        {stage === 'decision' && link(a.id, 'Decide', '#rubric')}
      </span>
    </li>);

  const staffRow = (r: OnboardingRow, stage: Stage) => {
    const ag = agr.get(r.user_id);
    const ap = waiting.get(r.user_id);
    const words = waitingWords(r.state.waiting_on);
    return (
      <li key={r.user_id} data-testid={`pipeline-staff-${r.user_id}`}>
        <span><b>{r.name}</b> ({r.functions.join(', ') || 'staff'})
          {stage === 'agreement' && <span className="small muted"><br />{ag?.open ? `Agreement sent ${day(ag.open.sent_at)}, waiting for their signature.` : 'No agreement sent yet.'}</span>}
          {stage !== 'agreement' && stage !== 'approval' && stage !== 'onboarded' && words && <span className="small muted"><br />{words}</span>}
        </span>
        <span className="ad-actions">
          {stage === 'agreement' && (admin && ag ? <SendGenerated docType="staff_agreement" who={r.user_id} refresh={refresh} /> : <span className="small muted">An Admin sends it.</span>)}
          {stage === 'academy' && (admin ? <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/admin/academy/staff/${r.user_id}`}>See their academy</Link> : <span className="small muted">They take the academy.</span>)}
          {stage === 'whatsapp' && (admin
            ? <Act ops action="staff_whatsapp_approve" payload={{ user: r.user_id }} label="Confirm WhatsApp and approve" variant="primary" refresh={refresh} done="Approved."
                confirm={`Mark ${r.name}'s WhatsApp groups confirmed and approve their onboarding? Their portal opens now.`} testId={`onboarding-wa-approve-${r.user_id}`} />
            : <span className="small muted">An Admin confirms the groups (or they do, on Welcome).</span>)}
          {stage === 'onboarded' && admin && !r.state.exempt && <Act ops action="staff_whatsapp_mark" payload={{ user: r.user_id, joined: false }} label="Take back WhatsApp" refresh={refresh} done="Taken back."
            confirm={`Take back ${r.name}'s WhatsApp confirmation? They lose access until they confirm again, and their leads go back.`} testId={`onboarding-revoke-${r.user_id}`} />}
          {stage === 'approval' && ap?.self && <span className="small muted">Someone else approves your own onboarding.</span>}
        </span>
      </li>);
  };

  const body = (key: Stage) => {
    if (key === 'approval') {
      // the Approve and Reject buttons (shared with the top of Staff and roles, Today and the Fleet portal)
      const rows = approvals.filter((a) => a.step !== 'whatsapp');
      return rows.length ? <OnboardingApprovals admin={admin} refresh={refresh} rows={rows} /> : null;
    }
    if (key === 'whatsapp') {
      const bulk = markable(g.staff.whatsapp);
      return (<>{admin && bulk.length > 1 && <div><Act ops action="staff_whatsapp_mark_all" label={`Mark joined: ${bulk.length} signed, not confirmed`} variant="primary" refresh={refresh} done="Marked."
        confirm={`Mark the WhatsApp groups joined for ${bulk.map((r) => r.name).join(', ')}?`} testId="onboarding-mark-all" /></div>}
        <ul className="mr-list">{g.staff.whatsapp.map((r) => staffRow(r, 'whatsapp'))}</ul></>);
    }
    const isApp = ['applied', 'ai', 'booked', 'decision'].includes(key);
    const list = isApp ? g.apps[key as keyof typeof g.apps].map((a) => appRow(a, key)) : g.staff[key as keyof typeof g.staff].map((r) => staffRow(r, key));
    if (key === 'onboarded') return list.length ? <details><summary className="link small">Show the {list.length} onboarded</summary><ul className="mr-list">{list}</ul></details> : null;
    return list.length ? <ul className="mr-list">{list}</ul> : null;
  };

  return (
    <div className="stack" data-testid="onboarding-pipeline">
      <nav aria-label="Pipeline stages" className="ad-filters" data-testid="pipeline-counts">
        {shown.map((s) => <a key={s.key} href={`#stage-${s.key}`} data-testid={`pipeline-count-${s.key}`} aria-current={undefined}>{s.label} <b>{g.counts[s.key]}</b></a>)}
      </nav>
      {shown.map((s, i) => {
        const content = body(s.key);
        return (
          <section key={s.key} id={`stage-${s.key}`} className="pt-card stack" aria-labelledby={`stage-h-${s.key}`} data-testid={`pipeline-stage-${s.key}`}>
            <h2 className="d4" id={`stage-h-${s.key}`}>{i + 1}. {s.label} <span className="muted">({g.counts[s.key]})</span></h2>
            <p className="small muted">{s.hint}</p>
            {content ?? <p className="small muted">Nobody here.</p>}
          </section>);
      })}
    </div>
  );
}
