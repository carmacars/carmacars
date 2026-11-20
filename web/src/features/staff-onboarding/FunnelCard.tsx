import Link from '@/components/Link';
import { Card } from '@/features/admin/ui';

// r48 FE (3191): the top of Admin > Hiring > Pipeline: the WhatsApp links that are missing (nobody can join a group
// without them), the Sales staff by academy progress, and the one-time re-send of the Sales referrals and interview links.
export interface Funnel {
  sales_academy: { people: number; not_started: number; in_progress: number; done: number; stalled_2_days: number };
  whatsapp_links_missing: string[];
  resends: { waiting: number; sent: number; reopened: number; skipped: number };
}
const LINK_NAME: Record<string, string> = { whatsapp_team_group_url: 'CarmaCars Team group', whatsapp_sales_group_url: 'Sales group (CARMA Closers)' };

export function FunnelCard({ f }: { f: Funnel | null }) {
  if (!f) return null;
  const a = f.sales_academy;
  return (
    <>
      {f.whatsapp_links_missing.length > 0 && <p className="alert alert--error" role="alert" data-testid="whatsapp-links-missing"><span>
        No WhatsApp link set for the {f.whatsapp_links_missing.map((k) => LINK_NAME[k] ?? k).join(' and the ')}: new staff see no link and cannot join. In WhatsApp: the group &gt; Invite via link &gt; Reset link (keep Add other members for admins only and Approve new participants on), then paste it in{' '}
        <Link prefetch={false} className="link" href="/admin/settings/program">Settings &gt; Program</Link>.</span></p>}
      <Card title="Sales funnel">
        <p className="small" data-testid="sales-academy-counts">Sales staff in the academy: {a.people} in all, {a.not_started} not started, {a.in_progress} in progress, {a.done} done{a.stalled_2_days ? `; ${a.stalled_2_days} with no progress for 2 days or more (nudged on day 1, 2 and 4)` : ''}.</p>
        {(f.resends.waiting + f.resends.sent + f.resends.reopened + f.resends.skipped) > 0 && <p className="small" data-testid="hiring-resends">Re-send of the Sales referrals and interview links: {f.resends.sent} sent, {f.resends.waiting} waiting (a few every 15 minutes), {f.resends.skipped} skipped (already applied or finished){f.resends.reopened ? `, ${f.resends.reopened} Sales applicants decided again on the corrected bar` : ''}.</p>}
      </Card>
    </>
  );
}
