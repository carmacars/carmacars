import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, Filters, PageHead, Search, Table, d } from '@/features/admin/ui';
import { MarketingTabs } from '@/features/ads/MarketingTabs';
import { CONTACT_KINDS, LEAD_STATUS, LISTING_SITES, type ConsentState } from '@/features/ads/recruit';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner recruitment', path: '/admin/marketing/recruit', noindex: true, description: 'Prospective owners from classified ads, their consent under the anti-spam law, calls and messages.' });
type Lead = { id: string; name: string | null; business_name: string | null; email: string | null; phone: string | null; listing_url: string | null; listing_site: string | null; contact_kind: string | null;
  vehicle_text: string | null; status: string; created_at: string; do_not_contact_at: string | null; email_state: ConsentState; text_state: ConsentState; last_message_at: string | null; last_call: { outcome: string; at: string } | null };
const word = (xs: Array<[string, string]>, k: string | null) => xs.find((x) => x[0] === k)?.[1] ?? '';
const state = (s: ConsentState) => s.allowed ? <Badge s="published">Allowed</Badge> : <span><Badge s="closed">No</Badge><span className="ad-sub">{s.reason}</span></span>;

// Admin > Marketing > Owner recruitment (migration 0167, the spec's task 9 and section 5): owners and co-hosts found in
// classified ads. Phone first (a live call is not covered by the anti-spam law); an email or a text goes only when the
// consent log allows it, names CarmaCars, its address, and carries the unsubscribe. Contact details are typed by staff
// from the ad; nothing is collected from the classified sites.
export default async function Recruit({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/marketing/recruit'), searchParams]);
  const status = sp.status ?? 'open';
  const r = await read<{ enabled: boolean; rows: Lead[]; counts: { all: number; open: number; do_not_contact: number } }>('recruit_leads', { status: status === 'all' ? '' : status, q: sp.q });
  return (<>
    <PageHead kicker="Marketing" title="Owner recruitment" purpose="Prospective owners from classified ads. Phone them first; email or text only with consent in the log.">
      <Act action="recruit_lead_save" label="Add a lead" variant="primary" testId="rc-add" go="/admin/marketing/recruit/{id}" done="Added."
        fields={[{ name: 'listing_url', label: 'The classified ad\'s address (https://...)', type: 'text', wide: true },
          { name: 'contact_kind', label: 'Who is selling', type: 'select', options: CONTACT_KINDS, value: 'private_seller', required: true },
          { name: 'name', label: 'Name', type: 'text' }, { name: 'business_name', label: 'Business name (a dealer or rental business)', type: 'text' },
          { name: 'phone', label: 'Phone (from the ad)', type: 'tel' }, { name: 'email', label: 'Email (only if they published it or gave it to you)', type: 'email' },
          { name: 'vehicle_text', label: 'The car (for example 2021 Honda Civic)', type: 'text' }, { name: 'listing_site', label: 'Site (found from the address if empty)', type: 'select', options: [['', 'From the address'], ...LISTING_SITES] },
          { name: 'note', label: 'Note', type: 'textarea' }]} />
    </PageHead>
    <MarketingTabs current="/admin/marketing/recruit" />
    {!r.enabled && <p className="alert small" role="status"><span>Recruitment emails and texts are off in Program settings: nothing sends until they are on.</span></p>}
    <div className="row" style={{ gap: '1rem', flexWrap: 'wrap', alignItems: 'center' }}>
      <Filters base="/admin/marketing/recruit" name="status" value={status} sp={sp} options={[['open', `Open (${r.counts.open})`], ['contacted', 'Contacted'], ['qualified', 'Interested'], ['converted', 'Signed up'], ['do_not_contact', `Do not contact (${r.counts.do_not_contact})`], ['all', `All (${r.counts.all})`]]} />
      <Search action="/admin/marketing/recruit" value={sp.q} placeholder="Search name, phone, car" />
    </div>
    <Table<Lead> testId="rc-leads" rows={r.rows} rowKey={(x) => x.id} empty="No recruitment lead yet. Add one from a classified ad." cols={[
      { key: 'name', label: 'Lead', render: (x) => <Link prefetch={false} className="link" href={`/admin/marketing/recruit/${x.id}`} data-testid="rc-lead-link">{x.business_name ?? x.name ?? x.phone ?? x.email}</Link> },
      { key: 'contact_kind', label: 'Who', render: (x) => word(CONTACT_KINDS, x.contact_kind) },
      { key: 'vehicle_text', label: 'Car', render: (x) => <>{x.vehicle_text}{x.listing_url ? <span className="ad-sub"><a className="link" href={x.listing_url} target="_blank" rel="noopener noreferrer nofollow">{word(LISTING_SITES, x.listing_site) || 'Ad'}</a></span> : null}</> },
      { key: 'status', label: 'Status', render: (x) => x.do_not_contact_at ? <Badge s="closed">Do not contact</Badge> : LEAD_STATUS[x.status] ?? x.status },
      { key: 'email_state', label: 'Email', className: 'wrap', render: (x) => state(x.email_state) },
      { key: 'text_state', label: 'Text', className: 'wrap', render: (x) => state(x.text_state) },
      { key: 'last_call', label: 'Last call', render: (x) => x.last_call ? d(x.last_call.at) : '' },
      { key: 'created_at', label: 'Added', render: (x) => d(x.created_at) }]} />
  </>);
}
