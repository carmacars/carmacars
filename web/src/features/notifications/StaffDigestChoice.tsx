import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';

// Profile > Notifications (release 29, C3; migration 0583): how often staff and Admin alerts come by email. Not urgent
// alerts are kept for one digest an hour (the default), one a day at 07:00, or none (in-app notices and phone alerts
// only). Urgent ones (a payment declined, documents to review for a pickup within 2 hours, the site down) still come on
// their own, at most 3 an hour.
const WORDS: Record<string, string> = { hourly: 'Hourly digest', daily: 'Daily digest', off: 'Off' };
export async function StaffDigestChoice({ userId, ops = false, refresh, className = 'pt-card ad-card stack' }: { userId: string; ops?: boolean; refresh: string[]; className?: string }) {
  const r = await door<{ digest: string }>(userId, ops ? 'ops_read' : 'admin_read', 'my_staff_digest', {}).catch(() => null);
  if (!r) return null;
  return (
    <section className={className} aria-labelledby="staff-digest-h" data-testid="staff-digest">
      <h2 className="d4" id="staff-digest-h">Notifications: alerts by email</h2>
      <p className="small">Now: <b data-testid="staff-digest-now">{WORDS[r.digest] ?? r.digest}</b>. Alerts that are not urgent come together in one email; urgent ones (a payment declined, documents to review for a pickup within 2 hours, the site down) still come on their own. Every alert is also in the bell and on your phone at once.</p>
      <Act ops={ops} action="my_staff_digest_save" label="Change how often" title="Alerts by email" submitLabel="Save" refresh={refresh} testId="staff-digest-change" done="Saved."
        fields={[{ name: 'digest', label: 'Alerts by email', type: 'select', required: true, value: r.digest, options: [['hourly', 'Hourly digest'], ['daily', 'Daily digest (07:00)'], ['off', 'Off (the bell and phone alerts only)']] }]} />
    </section>
  );
}
