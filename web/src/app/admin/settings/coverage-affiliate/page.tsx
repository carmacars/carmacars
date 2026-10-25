import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, Card, Kv, PageHead, Table, Tiles, d, t } from '@/features/admin/ui';
import { PLACEMENT_WORDS } from '@/features/referral/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'RentalCoverage affiliate', path: '/admin/settings/coverage-affiliate', noindex: true, description: 'The RentalCoverage affiliate link, its clicks and what was received.' });
type R = Record<string, unknown>;
type Data = { today: string; settings: { display_name: string; link_url: string | null; affiliate_id: string | null; enabled: boolean; usable: boolean; updated_at: string };
  totals: { clicks: number; clicks_30d: number; visitors: number; with_booking: number; received_cents: number }; by_place: R[]; by_month: R[]; recent: R[]; payments: R[] };

// Admin > Settings > RentalCoverage affiliate (migration 0164): paste the affiliate link (and the ID when the link has {id} in it)
// and the site starts suggesting it wherever it mentions coverage from another company. Clicks are counted here; RentalCoverage
// reports the sales, so what they pay is entered by hand.
export default async function CoverageAffiliate() {
  const { read } = await page('/admin/settings/coverage-affiliate');
  const a = await read<Data>('coverage_affiliate');
  const s = a.settings;
  const refresh = ['/admin/settings/coverage-affiliate'];
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/settings">Settings</Link>} title="RentalCoverage affiliate"
      purpose="A commission when a renter buys a policy through the link on our site. Off until you paste the link RentalCoverage gives you." />
    <Card title="The link" testId="ca-settings" aside={s.usable ? <Badge s="published">On</Badge> : <Badge s="draft">{s.enabled ? 'Not live yet' : 'Off'}</Badge>}>
      <Kv rows={[['Name shown', s.display_name], ['Affiliate link', s.link_url ?? 'Not set'], ['Affiliate ID', s.affiliate_id], ['Shown on the site', s.usable ? 'Yes' : s.enabled ? 'No: the link has {id} in it and no ID is set' : 'No']]} />
      <Act action="coverage_affiliate_save" label={s.link_url ? 'Change the link' : 'Paste the affiliate link'} variant="primary" testId="ca-save" refresh={refresh} done="Saved."
        fields={[{ name: 'link_url', label: 'Affiliate link (starts with https://)', type: 'text', value: s.link_url, wide: true, hint: 'Paste it exactly as your affiliate dashboard gives it. If it has {id} in it, that part is replaced by the ID below.' },
          { name: 'affiliate_id', label: 'Affiliate ID (only if the link has {id} in it)', type: 'text', value: s.affiliate_id },
          { name: 'display_name', label: 'Name shown to renters', type: 'text', value: s.display_name },
          { name: 'enabled', label: 'Show the link on the site', type: 'bool', value: s.enabled || !s.link_url }]} />
      <p className="small muted">Where it shows once on: Requirements and coverage, the credit card coverage guide, and the coverage step of the booking request. Each says it is a separate company&apos;s optional product, that it does not replace the coverage option the renter chooses, that CarmaCars may earn a commission and that it costs the renter nothing extra. Nothing is said about what it covers. Visitors go through a CarmaCars address that counts the click and adds utm_source=carmacars, utm_medium=referral and utm_campaign=coverage_&lt;place&gt;.</p>
    </Card>
    <Tiles items={[{ k: 'Clicks, last 30 days', v: a.totals.clicks_30d }, { k: 'Clicks, all time', v: a.totals.clicks }, { k: 'Visitors', v: a.totals.visitors, sub: 'with the site cookie' },
      { k: 'Clicks from a booking', v: a.totals.with_booking }, { k: 'Received so far', v: $(a.totals.received_cents) }]} />
    <Card title="Clicks by place" testId="ca-places">
      <Table<R> rows={a.by_place} rowKey={(x) => String(x.placement)} empty="No clicks yet." cols={[{ key: 'placement', label: 'Where', render: (x) => PLACEMENT_WORDS[String(x.placement)] ?? String(x.placement) },
        { key: 'clicks', label: 'Clicks', num: true }, { key: 'visitors', label: 'Visitors', num: true }, { key: 'with_booking', label: 'From a booking', num: true }]} />
    </Card>
    <Card title="Clicks by month">
      <Table<R> rows={a.by_month} rowKey={(x) => String(x.month)} empty="No clicks yet." cols={[{ key: 'month', label: 'Month' }, { key: 'clicks', label: 'Clicks', num: true }, { key: 'visitors', label: 'Visitors', num: true }]} />
    </Card>
    <Card title="What RentalCoverage paid us" testId="ca-payments" aside={<Act action="coverage_affiliate_payment_add" label="Add a payment received" testId="ca-pay" refresh={refresh} done="Entered."
      fields={[{ name: 'received_on', label: 'Date received', type: 'date', required: true, value: a.today }, { name: 'amount_cents', label: 'Amount', type: 'money', required: true }, { name: 'period_note', label: 'What period or sales it covers', type: 'text' },
        { name: 'reference', label: 'Their statement or payment reference', type: 'text' }, { name: 'note', label: 'Note', type: 'text' }]} />}>
      <p className="small muted">RentalCoverage reports the sales and pays the commission: this site cannot see them. Enter each payment when it arrives.</p>
      <Table<R> rows={a.payments} rowKey={(x) => String(x.id)} empty="Nothing received yet." cols={[{ key: 'received_on', label: 'Received', render: (x) => d(x.received_on) }, { key: 'amount_cents', label: 'Amount', num: true, render: (x) => $(x.amount_cents) },
        { key: 'period_note', label: 'Covers', className: 'wrap' }, { key: 'reference', label: 'Reference' }, { key: 'note', label: 'Note', className: 'wrap' }]} />
    </Card>
    <Card title="Latest clicks">
      <Table<R> rows={a.recent} rowKey={(x, i) => `${String(x.at)}-${i}`} empty="No clicks yet." cols={[{ key: 'at', label: 'When', render: (x) => t(x.at) }, { key: 'placement', label: 'Where', render: (x) => PLACEMENT_WORDS[String(x.placement)] ?? String(x.placement) }, { key: 'booking_number', label: 'Booking' }]} />
    </Card>
  </>);
}
