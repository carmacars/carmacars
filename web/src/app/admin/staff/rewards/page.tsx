import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, Card, d, Kv, PageHead, Table, Tiles } from '@/features/admin/ui';
import { pct } from '@/features/staff-rewards/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Staff rewards', path: '/admin/staff/rewards', noindex: true, description: 'Who gets staff perks, their tier and free days, what was used and what it cost.' });

type R = Record<string, unknown>;
type Data = {
  settings: { enabled: boolean; base_bps: number; days_per_free_day: number; handovers_per_free_day: number; silver_days: number; silver_bps: number; gold_days: number; gold_bps: number; gold_bonus_days: number;
    top_seller_days: number; max_ahead_hours: number; expiry_months: number; count_from: string };
  month: string; cost_month_cents: number; cost_year_cents: number;
  staff: Array<{ user_id: string; name: string; functions: string[]; eligible: boolean; frozen: boolean; why_not: string | null; override: boolean | null; tier: string; month_days: number; total_days: number; handovers: number; free_days: number; used_cents: number }>;
  used: Array<{ expense_on: string; description: string; amount_cents: number; name: string | null }> };
const TIER: Record<string, string> = { member: 'Member', silver: 'Silver', gold: 'Gold' };

// Admin > Team > Staff rewards (release 48, migration 3261): every staff member with whether they get rental perks and
// why not (remote and international staff never do), their tier, progress and free days, what was used and its cost in
// the books (staff benefit, account 5300). Every number is in Program settings.
export default async function StaffRewardsAdmin() {
  const { read } = await page('/admin/staff/rewards');
  const a = await read<Data>('staff_perks');
  const s = a.settings;
  const refresh = ['/admin/staff/rewards'];
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/settings/staff">Team</Link>} title="Staff rewards"
      purpose="A discount on their own rentals and free rental days they earn. In-person staff in Canada only." />
    <Tiles items={[{ k: 'Eligible now', v: a.staff.filter((x) => x.eligible).length }, { k: 'No rental perks', v: a.staff.filter((x) => !x.eligible).length },
      { k: `Used in ${a.month}`, v: $(a.cost_month_cents) }, { k: 'Used this year', v: $(a.cost_year_cents) }]} />
    <Card title="The program" testId="sr-settings" aside={s.enabled ? <Badge s="published">On</Badge> : <Badge s="draft">Off</Badge>}>
      <Kv rows={[['From day one (academy and agreement done)', `${pct(s.base_bps)} off their own rentals`],
        ['Free days', `Sales: 1 per ${s.days_per_free_day} rental days booked. Field: 1 per ${s.handovers_per_free_day} handovers.`],
        ['Silver', `${s.silver_days} rental days booked in a month: ${pct(s.silver_bps)} off`],
        ['Gold', `${s.gold_days} rental days booked in a month: ${pct(s.gold_bps)} off and ${s.gold_bonus_days} bonus free day${s.gold_bonus_days === 1 ? '' : 's'}`],
        ['Top seller of the month', `${s.top_seller_days} free days${s.top_seller_days === 2 ? ' (a weekend)' : ''}`],
        ['Never in the way of a renter', `Pickup within ${s.max_ahead_hours} hours of booking; never on dates a renter asked for; no exotic or partner cars`],
        ['A free day ends after', `${s.expiry_months} months`], ['Counted from', d(s.count_from)]]} />
      <p className="small muted">Free days go on CarmaCars&apos; and shareholders&apos; cars first; on a co-host owner&apos;s car the owner is paid as at the full rate. Each perk used is posted as a staff benefit expense. Change any number under <Link prefetch={false} className="link" href="/admin/settings/program">Settings &gt; Program settings &gt; Staff rewards</Link>.</p>
    </Card>
    <Card title="Staff" testId="sr-staff">
      <Table<R> rows={a.staff as unknown as R[]} rowKey={(x) => String(x.user_id)} empty="No active staff yet." cols={[
        { key: 'name', label: 'Person', className: 'wrap', render: (x) => <><b>{String(x.name)}</b><br /><span className="small muted">{(x.functions as string[]).join(', ')}</span></> },
        { key: 'eligible', label: 'Rental perks', className: 'wrap', render: (x) => (x.eligible ? <Badge s="published">On</Badge> : <><Badge s={x.frozen ? 'closed' : 'draft'}>{x.frozen ? 'Frozen' : 'None'}</Badge><br /><span className="small muted">{String(x.why_not ?? '')}</span></>) },
        { key: 'tier', label: 'Tier', render: (x) => (x.eligible ? TIER[String(x.tier)] ?? String(x.tier) : '') },
        { key: 'month_days', label: 'Days booked this month', num: true }, { key: 'total_days', label: 'Days counted', num: true }, { key: 'handovers', label: 'Handovers', num: true },
        { key: 'free_days', label: 'Free days', num: true }, { key: 'used_cents', label: 'Used', num: true, render: (x) => $(x.used_cents) },
        { key: 'act', label: '', render: (x) => <span className="ad-actions">
          <Act action="staff_perk_set" payload={{ user: x.user_id }} label="Perks" refresh={refresh} done="Saved." testId={`sr-set-${String(x.user_id).slice(0, 8)}`} title={`Rental perks: ${String(x.name)}`}
            fields={[{ name: 'eligible', label: 'Rental perks for this person', type: 'select', value: x.override === true ? 'yes' : x.override === false ? 'no' : '', options: [['', 'By the rule (in person, in Canada)'], ['yes', 'On'], ['no', 'Off']] },
              { name: 'note', label: 'Why (they read it when it is off)', type: 'text', wide: true }]} />
          <Act action="staff_perk_adjust" payload={{ user: x.user_id }} label="Add free days" variant="quiet" refresh={refresh} done="Added. They were told." testId={`sr-adjust-${String(x.user_id).slice(0, 8)}`} title={`Free days for ${String(x.name)}`}
            fields={[{ name: 'days', label: 'Free days', type: 'number', required: true, value: 1, min: 1, max: 7 }, { name: 'note', label: 'What for (they read it)', type: 'text', required: true, wide: true }]} /></span> }]} />
    </Card>
    <Card title="Used" testId="sr-used">
      <Table<R> rows={a.used as unknown as R[]} rowKey={(x) => `${String(x.expense_on)}-${String(x.description)}`} empty="No perk has been used yet. Each use shows here and in the books as a staff benefit." cols={[
        { key: 'expense_on', label: 'Day', render: (x) => d(x.expense_on) }, { key: 'name', label: 'Person' }, { key: 'description', label: 'What', className: 'wrap' },
        { key: 'amount_cents', label: 'Amount', num: true, render: (x) => $(x.amount_cents) }]} />
    </Card>
  </>);
}
