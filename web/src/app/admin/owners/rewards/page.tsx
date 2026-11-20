import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, Card, d, Kv, PageHead, t, Table, Tiles } from '@/features/admin/ui';
import { pct } from '@/features/owner-rewards/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner rewards', path: '/admin/owners/rewards', noindex: true, description: 'Merch kits to ship, upgrades to approve, credits, and what owner rewards cost.' });

type R = Record<string, unknown>;
type Data = {
  settings: { enabled: boolean; fleet_bps: number; ff_bps: number; kickback_bps: number; refer_cents: number; refer_live_days: number; merch_months: number; merch_premium_months: number;
    merch_cost_cents: number; merch_premium_cost_cents: number; birthday_cents: number; upgrade_default_cents: number };
  requests: Array<{ id: string; kind: string; status: string; owner_id: string; owner: string; created_at: string; car: string | null; note: string | null; size: string | null; ship_to: string | null; phone: string | null;
    shipped_at: string | null; tracking: string | null; decision_note: string | null; cost_cents: number | null; default_cost_cents: number }>;
  owners: Array<{ owner_id: string; name: string; months: number; since: string | null; code: string | null; friend_rentals: number; credits_cents: number }>;
  cost_month_cents: number; cost_year_cents: number; recent: Array<{ at: string; owner: string; title: string; detail: string | null; amount_cents: number | null }> };
const KIND: Record<string, string> = { merch_kit: 'Merch kit', merch_kit_premium: 'Premium merch kit', upgrade: 'Free upgrade' };
const STATUS: Record<string, [string, string]> = { requested: ['submitted', 'Waiting'], shipped: ['published', 'Shipped'], approved: ['published', 'Approved'], declined: ['closed', 'Declined'], cancelled: ['closed', 'Cancelled'] };

// Admin > People > Owners > Owner rewards (release 48, migration 3262): the kits owners redeemed (ship, then mark it
// shipped: the owner is told and its cost is posted), the upgrades owners asked for (approve with the amount CarmaCars
// covers, or decline with the reason), a credit by hand, every owner's months and code, and what it all cost.
export default async function OwnerRewardsAdmin() {
  const { read } = await page('/admin/owners/rewards');
  const a = await read<Data>('owner_rewards');
  const s = a.settings;
  const refresh = ['/admin/owners/rewards', '/admin'];
  const open = a.requests.filter((x) => x.status === 'requested');
  const done = a.requests.filter((x) => x.status !== 'requested');
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/owners">Owners</Link>} title="Owner rewards"
      purpose="Kits to ship, upgrades to answer, credits, and every owner's rewards. Owners see theirs under Rewards in their portal." />
    <Tiles items={[{ k: 'Kits to ship', v: open.filter((x) => x.kind !== 'upgrade').length, warn: open.some((x) => x.kind !== 'upgrade') }, { k: 'Upgrades to answer', v: open.filter((x) => x.kind === 'upgrade').length, warn: open.some((x) => x.kind === 'upgrade') },
      { k: 'Cost this month', v: $(a.cost_month_cents) }, { k: 'Cost this year', v: $(a.cost_year_cents) }]} />

    <Card title="To do" testId="orw-todo" tone={open.length ? 'next' : undefined}>
      <Table<R> rows={open as unknown as R[]} rowKey={(x) => String(x.id)} empty="Nothing to ship or answer. A kit an owner redeems or an upgrade they ask for shows here and on To do." cols={[
        { key: 'owner', label: 'Owner', className: 'wrap', render: (x) => <Link prefetch={false} className="link" href={`/admin/owners/${String(x.owner_id)}`}>{String(x.owner)}</Link> },
        { key: 'kind', label: 'What', render: (x) => KIND[String(x.kind)] ?? String(x.kind) },
        { key: 'detail', label: 'Details', className: 'wrap', render: (x) => (x.kind === 'upgrade' ? <>{String(x.car ?? '')}<br /><span className="small muted">{String(x.note ?? '')}</span></>
          : <>{String(x.ship_to ?? '')}<br /><span className="small muted">{[x.size ? `Size ${String(x.size)}` : '', x.phone ? String(x.phone) : ''].filter(Boolean).join(' · ')}</span></>) },
        { key: 'created_at', label: 'Asked', render: (x) => t(x.created_at) },
        { key: 'act', label: '', render: (x) => (x.kind === 'upgrade'
          ? <span className="ad-actions">
              <Act action="owner_reward_upgrade_decide" payload={{ id: x.id, approve: 'yes' }} label="Approve" variant="primary" refresh={refresh} done="Approved. The owner has their code." testId={`orw-approve-${String(x.id).slice(0, 8)}`} title="Approve the free upgrade"
                fields={[{ name: 'amount_cents', label: 'What CarmaCars covers (the price difference)', type: 'money', required: true, value: x.default_cost_cents }, { name: 'note', label: 'A line for the owner (optional)', type: 'text', wide: true }]} />
              <Act action="owner_reward_upgrade_decide" payload={{ id: x.id, approve: 'no' }} label="Decline" variant="quiet" refresh={refresh} done="Declined. The owner was told why." testId={`orw-decline-${String(x.id).slice(0, 8)}`} title="Decline the upgrade"
                fields={[{ name: 'note', label: 'Why (the owner reads it)', type: 'text', required: true, wide: true }]} /></span>
          : <Act action="owner_reward_ship" payload={{ id: x.id }} label="Mark shipped" variant="primary" refresh={refresh} done="Shipped. The owner was told." testId={`orw-ship-${String(x.id).slice(0, 8)}`} title={`Shipped: ${KIND[String(x.kind)]}`}
              fields={[{ name: 'tracking', label: 'Tracking number (optional)', type: 'text' }, { name: 'cost_cents', label: 'What the kit and postage cost (posted to the books)', type: 'money', value: x.default_cost_cents }]} />) }]} />
    </Card>

    <Card title="The program" testId="orw-settings" aside={s.enabled ? <Badge s="published">On</Badge> : <Badge s="draft">Off</Badge>}>
      <Kv rows={[['Fleet discount while their car is out', `${pct(s.fleet_bps)} off another car (never exotic or partner cars)`],
        ['Friends and family', `${pct(s.ff_bps)} off a friend's first rental; the owner earns the ${pct(s.kickback_bps)} kickback`],
        ['Refer an owner', `${$(s.refer_cents)} credit once the new car has been live ${s.refer_live_days} days`],
        ['Merch kits', `${s.merch_months} months: merch kit. ${s.merch_premium_months} months: premium kit. Redeemed by the owner's button, never automatic`],
        ['Birthday', `${$(s.birthday_cents)} rental credit`], ['Also', 'Priority support and early access to new programs']]} />
      <p className="small muted">A credit is a line on the owner&apos;s statement and an expense in the books (Owner rewards and credits, account 5310). The management fee and the statements are otherwise unchanged. Change any number under <Link prefetch={false} className="link" href="/admin/settings/program">Settings &gt; Program settings &gt; Owner rewards</Link>.</p>
    </Card>

    <Card title="Owners" testId="orw-owners">
      <Table<R> rows={a.owners as unknown as R[]} rowKey={(x) => String(x.owner_id)} empty="No owners in the program yet." cols={[
        { key: 'name', label: 'Owner', className: 'wrap', render: (x) => <><Link prefetch={false} className="link" href={`/admin/owners/${String(x.owner_id)}`}>{String(x.name)}</Link> <Badge s="published">Priority support</Badge></> },
        { key: 'months', label: 'Months in', num: true }, { key: 'since', label: 'Since', render: (x) => d(x.since) }, { key: 'code', label: 'Friends and family code' },
        { key: 'friend_rentals', label: 'Friends who rented', num: true }, { key: 'credits_cents', label: 'Credits', num: true, render: (x) => $(x.credits_cents) },
        { key: 'act', label: '', render: (x) => <Act action="owner_reward_credit" payload={{ owner: x.owner_id }} label="Add a credit" variant="quiet" refresh={refresh} done="Added. It is on their next statement and they were told." testId={`orw-credit-${String(x.owner_id).slice(0, 8)}`} title={`A credit for ${String(x.name)}`}
          fields={[{ name: 'amount_cents', label: 'Amount', type: 'money', required: true }, { name: 'note', label: 'What for (the owner reads it on the statement)', type: 'text', required: true, wide: true }]} /> }]} />
    </Card>

    <Card title="Shipped and answered" testId="orw-done">
      <Table<R> rows={done as unknown as R[]} rowKey={(x) => String(x.id)} empty="Nothing yet." cols={[
        { key: 'owner', label: 'Owner', className: 'wrap' }, { key: 'kind', label: 'What', render: (x) => KIND[String(x.kind)] ?? String(x.kind) },
        { key: 'status', label: 'Status', render: (x) => <Badge s={STATUS[String(x.status)]?.[0] ?? 'draft'}>{STATUS[String(x.status)]?.[1] ?? String(x.status)}</Badge> },
        { key: 'when', label: 'When', render: (x) => t(x.shipped_at ?? x.created_at) }, { key: 'tracking', label: 'Tracking', render: (x) => String(x.tracking ?? x.decision_note ?? '') },
        { key: 'cost_cents', label: 'Cost', num: true, render: (x) => $(x.cost_cents) }]} />
    </Card>

    <Card title="Latest rewards" testId="orw-recent">
      <Table<R> rows={a.recent as unknown as R[]} rowKey={(x) => `${String(x.at)}-${String(x.title)}`} empty="No reward yet." cols={[
        { key: 'at', label: 'When', render: (x) => t(x.at) }, { key: 'owner', label: 'Owner' }, { key: 'title', label: 'Reward', className: 'wrap', render: (x) => <>{String(x.title)}<br /><span className="small muted">{String(x.detail ?? '')}</span></> },
        { key: 'amount_cents', label: 'Amount', num: true, render: (x) => $(x.amount_cents) }]} />
    </Card>
  </>);
}
