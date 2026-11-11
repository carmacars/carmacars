import { Act } from './Act';
import type { NameChange } from '@/server/self-profile';

// Release 34 (0812): a name change someone asked for, on that person's page and in To do: Approve changes the name on their
// account and record; Decline changes nothing.
export function NameChangeCard({ items, refresh }: { items: NameChange[]; refresh: string[] }) {
  if (!items.length) return null;
  return (
    <section className="pt-card ad-card" aria-labelledby="nc-t" data-testid="name-change-card">
      <h2 className="d4" id="nc-t">Name change asked for</h2>
      {items.map((n) => (
        <div key={n.id} className="stack" data-testid="name-change-item">
          <p><b>{n.current_name}</b>{n.requested_name !== n.current_name ? <> to <b>{n.requested_name}</b></> : null}{n.requested_dob ? <>; date of birth <b>{n.current_dob ?? 'none'}</b> to <b data-testid="name-change-dob">{n.requested_dob}</b></> : null}{n.reason ? <>: {n.reason}</> : null}</p>
          {n.requested_dob && <p className="small muted">Check it against the licence: the date of birth decides the young driver fee and the insurer&apos;s eligibility.</p>}
          <div className="ad-actions">
            <Act ops action="name_change_decide" payload={{ id: n.id, decision: 'approve' }} label="Approve" variant="primary" refresh={refresh} done="Name changed." testId="name-change-approve" />
            <Act ops action="name_change_decide" payload={{ id: n.id, decision: 'decline' }} label="Decline" fields={[{ name: 'note', label: 'Why (kept in the log)', type: 'text' }]} refresh={refresh} done="Declined." testId="name-change-decline" />
          </div>
        </div>))}
    </section>
  );
}
