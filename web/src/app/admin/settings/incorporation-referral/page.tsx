import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { $, Badge, Card, Kv, PageHead, Table, Tiles, d, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Incorporation referral', path: '/admin/settings/incorporation-referral', noindex: true, description: 'The online incorporation provider owners are referred to, who was referred and the commission.' });
type R = Record<string, unknown>;
type Data = { today: string; settings: { provider_name: string; link_template: string | null; commission_note: string; signup_url: string; enabled: boolean; usable: boolean; updated_at: string };
  totals: { referred: number; incorporated: number; received_cents: number; waiting: number }; referrals: R[] };
const STATUS: Record<string, string> = { clicked: 'Opened the link', incorporated: 'Incorporated', commission_received: 'Commission received', void: 'Void' };

// Admin > Settings > Incorporation referral (r50, 4511): an owner whose route needs a corporation (Lease through a new Owner
// Corporation) gets "Incorporate now" in their pipeline, with this provider's affiliate link. Off until the affiliate link
// is pasted. Each owner who opens it is recorded with a code sent in the link ({ref}), so the provider's commission report
// can be matched; the provider pays the commission, so it is entered here by hand.
export default async function IncorporationReferral() {
  const { read } = await page('/admin/settings/incorporation-referral');
  const a = await read<Data>('incorporation_referral');
  const s = a.settings;
  const refresh = ['/admin/settings/incorporation-referral'];
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/settings">Settings</Link>} title="Incorporation referral"
      purpose="Owners who need a corporation for the lease route are sent to an online incorporation provider. Off until you paste your affiliate link." />
    <Card title="The provider and the link" testId="ir-settings" aside={s.usable ? <Badge s="published">On</Badge> : <Badge s="draft">{s.enabled ? 'Not live yet' : 'Off'}</Badge>}>
      <Kv rows={[['Provider', s.provider_name], ['Affiliate link', s.link_template ?? 'Not set'], ['Commission', s.commission_note], ['Shown to owners', s.usable ? 'Yes: Incorporate now' : 'No: owners are asked to upload their corporate documents']]} />
      {!s.link_template && <p className="small">Sign up for the affiliate program first (your click): <a className="link" href={s.signup_url} target="_blank" rel="noopener noreferrer" data-testid="ir-signup">{s.signup_url}</a>. Then paste the tracking link it gives you here.</p>}
      <Act action="incorporation_referral_save" label={s.link_template ? 'Change the link' : 'Paste the affiliate link'} variant="primary" testId="ir-save" refresh={refresh} done="Saved."
        fields={[{ name: 'link_template', label: 'Affiliate link (starts with https://)', type: 'text', value: s.link_template, wide: true, hint: 'Paste it exactly as the provider gives it. Put {ref} where a sub-ID goes if the program allows one: each owner then gets their own code, for matching the commission report.' },
          { name: 'provider_name', label: 'Provider name shown to owners', type: 'text', value: s.provider_name },
          { name: 'commission_note', label: 'Commission (for your records)', type: 'text', value: s.commission_note, wide: true },
          { name: 'enabled', label: 'Show Incorporate now to owners', type: 'bool', value: s.enabled || !s.link_template }]} />
    </Card>
    <Tiles items={[{ k: 'Owners referred', v: a.totals.referred }, { k: 'Incorporated', v: a.totals.incorporated }, { k: 'Commission received', v: $(a.totals.received_cents) }, { k: 'Waiting on Incorporate now', v: a.totals.waiting, sub: 'cars in that step' }]} />
    <Card title="Who was referred" testId="ir-referrals">
      <p className="small muted">One row an owner: the code sent with the link, when they first and last opened it, and the car. Mark Incorporated when you see it in the provider&apos;s report, then Commission received when it is paid.</p>
      <Table<R> rows={a.referrals} rowKey={(x) => String(x.id)} empty="Nobody referred yet." cols={[{ key: 'owner', label: 'Owner', render: (x) => <Link prefetch={false} className="link" href={`/admin/owners/${String(x.owner_id)}`}>{String(x.owner)}</Link> },
        { key: 'car', label: 'Car' }, { key: 'ref_code', label: 'Code' }, { key: 'first_clicked_at', label: 'First opened', render: (x) => t(x.first_clicked_at) }, { key: 'clicks', label: 'Opens', num: true },
        { key: 'status', label: 'Status', render: (x) => <Badge s={x.status === 'commission_received' ? 'published' : x.status === 'void' ? 'closed' : 'draft'}>{STATUS[String(x.status)] ?? String(x.status)}</Badge> },
        { key: 'commission_cents', label: 'Commission', num: true, render: (x) => $(x.commission_cents) }, { key: 'commission_on', label: 'Received', render: (x) => d(x.commission_on) },
        { key: 'act', label: '', render: (x) => <Act action="incorporation_referral_mark" payload={{ id: x.id }} label="Update" variant="quiet" refresh={refresh} done="Saved." testId={`ir-mark-${String(x.id).slice(0, 8)}`}
          fields={[{ name: 'status', label: 'Status', type: 'select', value: x.status, options: [['clicked', 'Opened the link'], ['incorporated', 'Incorporated'], ['commission_received', 'Commission received'], ['void', 'Void']] },
            { name: 'incorporated_on', label: 'Incorporated on', type: 'date', value: x.incorporated_on }, { name: 'commission_cents', label: 'Commission received', type: 'money', value: x.commission_cents },
            { name: 'commission_on', label: 'Received on', type: 'date', value: x.commission_on ?? a.today }, { name: 'note', label: 'Note', type: 'text', value: x.note }]} /> }]} />
    </Card>
  </>);
}
