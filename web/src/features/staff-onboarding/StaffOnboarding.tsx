import { Act } from '@/features/admin/Act';
import { markable, rowWords, STEP_LABEL, waitingWords, type OnboardingRow } from './model';

const REFRESH = ['/admin/settings/staff'];

// Admin > Settings > Staff (1151): where every active staff member is in onboarding (the academy, the agreement, the WhatsApp
// groups, in that order; nothing else opens until all three are done). An Admin marks the WhatsApp step joined for one person
// or takes it back (their leads then go back to the salesperson who had them, or to the pool), or marks every signed person
// who has not confirmed in one press.
export function StaffOnboarding({ rows }: { rows: OnboardingRow[] }) {
  const held = rows.filter((r) => !r.onboarded);
  const bulk = markable(rows);
  return (
    <div className="stack" data-testid="staff-onboarding">
      <p className="small">{held.length ? `${held.length} not fully onboarded: they open only Welcome and their onboarding until done.` : 'Everyone is onboarded.'} The order: the academy, the staff agreement, then the WhatsApp groups (Sales: the Sales group and the Team group; everyone else the Team group), confirmed by the person or marked here. Leads never go to someone not onboarded.</p>
      {bulk.length > 0 && <div><Act ops action="staff_whatsapp_mark_all" label={`Mark joined: ${bulk.length} signed, not confirmed`} variant="primary" refresh={REFRESH} done="Marked."
        confirm={`Mark the WhatsApp groups joined for ${bulk.map((r) => r.name).join(', ')}?`} testId="onboarding-mark-all" /></div>}
      <ul className="mr-list">{rows.map((r) => (
        <li key={r.user_id} data-testid={`onboarding-row-${r.user_id}`}>
          <span><b>{r.name}</b> ({STEP_LABEL[r.onboarded ? 'done' : r.state.step]}): {rowWords(r)}
            {!r.onboarded && waitingWords(r.state.waiting_on) && <span className="small muted" data-testid={`onboarding-row-waiting-${r.user_id}`}><br />{waitingWords(r.state.waiting_on)}</span>}</span>
          {!r.state.exempt && !r.onboarded && r.state.academy && r.state.agreement && <Act ops action="staff_whatsapp_approve" payload={{ user: r.user_id }} label={r.state.whatsapp ? 'Approve' : 'Confirm WhatsApp and approve'} variant="primary" refresh={REFRESH} done="Approved."
            confirm={`${r.state.whatsapp ? 'Approve' : 'Mark the WhatsApp groups confirmed and approve'} ${r.name}'s onboarding? Their portal opens now.`} testId={`onboarding-row-approve-${r.user_id}`} />}
          {!r.state.exempt && (r.state.whatsapp
            ? <Act ops action="staff_whatsapp_mark" payload={{ user: r.user_id, joined: false }} label="Take back WhatsApp" refresh={REFRESH} done="Taken back."
                confirm={`Take back ${r.name}'s WhatsApp confirmation? They lose access until they confirm again, and their leads go back.`} testId={`onboarding-revoke-${r.user_id}`} />
            : <Act ops action="staff_whatsapp_mark" payload={{ user: r.user_id, joined: true }} label="Mark WhatsApp joined" refresh={REFRESH} done="Marked." testId={`onboarding-mark-${r.user_id}`} />)}
        </li>))}</ul>
    </div>
  );
}
