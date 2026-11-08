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
          <p><b>{n.current_name}</b> to <b>{n.requested_name}</b>{n.reason ? <>: {n.reason}</> : null}</p>
          <p className="ad-actions">
            <Act ops action="name_change_decide" payload={{ id: n.id, decision: 'approve' }} label="Approve the name" variant="primary" refresh={refresh} done="Name changed." testId="name-change-approve" />
            <Act ops action="name_change_decide" payload={{ id: n.id, decision: 'decline' }} label="Decline" fields={[{ name: 'note', label: 'Why (kept in the log)', type: 'text' }]} refresh={refresh} done="Declined." testId="name-change-decline" />
          </p>
        </div>))}
    </section>
  );
}
