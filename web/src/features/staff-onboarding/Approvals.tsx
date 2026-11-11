import { Act } from '@/features/admin/Act';
import type { ApprovalRow } from './model';

const when = (iso: string | null) => (iso ? new Date(iso).toLocaleString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '');

// Onboarding step 4 (1154): the staff members who confirmed the WhatsApp groups and wait for an Admin or a Fleet VA to approve.
// Approve opens their portal; Reject (with the reason, shown on their Welcome) keeps them held until they ask again. Shared by
// Admin > Settings > Staff onboarding and the Fleet portal's Field jobs page.
export function OnboardingApprovals({ rows, refresh, admin }: { rows: ApprovalRow[]; refresh: string[]; admin?: boolean }) {
  if (!rows.length) return <p className="small muted" data-testid="onboarding-approvals-empty">Nobody is waiting for onboarding approval.</p>;
  const others = rows.filter((r) => !r.self);
  return (
    <div className="stack" id="onboarding-approvals" data-testid="onboarding-approvals">
      <p className="small">{rows.length} waiting for approval: they passed the academy, signed the agreement and joined the WhatsApp groups. Their portal opens once you approve.</p>
      {admin && others.length > 1 && <div><Act ops action="staff_onboarding_approve_all" label={`Approve all ${others.length}`} variant="primary" refresh={refresh} done="Approved."
        confirm={`Approve the onboarding of ${others.map((r) => r.name).join(', ')}?`} testId="onboarding-approve-all" /></div>}
      <ul className="mr-list">{rows.map((r) => (
        <li key={r.user_id} data-testid={`onboarding-approval-${r.user_id}`}>
          <span><b>{r.name}</b> ({r.functions.join(', ') || 'staff'}){r.asked_at ? `, asked ${when(r.asked_at)}` : ''}{r.reject_reason ? `. Rejected: ${r.reject_reason}` : ''}</span>
          {r.self ? <span className="small muted">Someone else approves your own onboarding.</span> : <span className="ad-actions">
            <Act ops action="staff_onboarding_approve" payload={{ user: r.user_id }} label={`Approve ${r.name}'s onboarding`} variant="primary" refresh={refresh} done="Approved."
              confirm={`Approve ${r.name}'s onboarding? Their portal opens now.`} testId={`onboarding-approve-${r.user_id}`} />
            <Act ops action="staff_onboarding_reject" payload={{ user: r.user_id }} label="Reject" title={`Reject ${r.name}'s onboarding`} submitLabel="Reject" refresh={refresh} done="Rejected."
              fields={[{ name: 'reason', label: 'Reason (they see it on Welcome)', required: true, placeholder: 'For example: join the Sales group with your work number' }]} testId={`onboarding-reject-${r.user_id}`} />
          </span>}
        </li>))}</ul>
    </div>
  );
}
