import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { Act } from '@/features/admin/Act';
import { Badge, Card, PageHead, Table, d } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Updated terms', path: '/admin/settings/terms', noindex: true, description: 'Publish a new version of the terms, the privacy policy or an agreement template, and see who accepted it.' });

type Acceptance = { name: string; email: string; accepted_at: string; ip_address: string | null; portal: string | null };
type Version = { id: string; doc_key: string; title: string; version: string; summary: string; requires_acceptance: boolean; published_at: string; published_by: string | null; accepted: number; acceptances: Acceptance[] | null };

const DOCS: Array<[string, string]> = [['terms', 'Terms of use (everyone with a portal)'], ['privacy', 'Privacy policy (everyone with a portal)'],
  ['rental_agreement', 'Rental agreement (renters)'], ['owner_agreement', 'Owner program agreements (owners)'], ['fleet_lease', 'Fleet Supplier Lease Agreement (fleet suppliers)'],
  ['partner_agreement', 'Partner agreement (partners)'], ['investment_agreement', 'Investment agreement (investors)'], ['staff_agreement', 'Staff and contractor agreement (staff and field)']];

// Admin > Settings > Updated terms (0721): publish a version with the "Requires acceptance" switch; everyone it binds sees
// "We've updated our terms" on their next visit to their portal and accepts it (who, when, the IP address, the version).
// The terms of use and the privacy policy also replace the text the site shows. A signed agreement is never voided.
export default async function UpdatedTerms({ searchParams }: { searchParams: Promise<{ v?: string }> }) {
  const { user } = await page('/admin/settings/terms');
  const { v } = await searchParams;
  const r = await door<{ versions: Version[] }>(user.id, 'admin_read', 'terms_versions', v && /^[0-9a-f-]{36}$/.test(v) ? { version_id: v } : {});
  const shown = r.versions.find((x) => x.id === v);
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Toronto' });
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/settings">Settings</Link>} title="Updated terms"
      purpose="Publish a new version; with Requires acceptance on, each person it binds accepts it before using their portal." />
    <Card title="Publish a new version" testId="terms-publish">
      <p className="small muted">Renters, owners, investors, staff and field whose account was opened before the version see a full-screen &quot;We&apos;ve updated our terms&quot; step with your summary and the new text, and press Accept. It is a click-through acceptance: no signed agreement is voided and no renter signs a past booking again. For the terms of use or the privacy policy, leave the text empty to use the site&apos;s current text; a text you paste also replaces the site&apos;s.</p>
      <Act action="terms_publish" label="Publish a version" variant="primary" testId="terms-publish-open" refresh={['/admin/settings/terms']} done="Published."
        fields={[{ name: 'doc_key', label: 'Document', type: 'select', options: DOCS, required: true },
          { name: 'version', label: 'Version', value: today, required: true, hint: 'For example the date it takes effect.' },
          { name: 'summary', label: 'What changed (people read this first)', type: 'textarea', required: true, wide: true },
          { name: 'body', label: 'The new text', type: 'textarea', wide: true, hint: 'Headings start with ###, list items with - . Empty for the terms of use or the privacy policy: the site’s current text.' },
          { name: 'requires_acceptance', label: 'Requires acceptance', type: 'bool', value: true }]} />
    </Card>
    <Card title="Versions" testId="terms-versions">
      <Table<Version> rows={r.versions} empty="No version published yet." rowKey={(x) => x.id} cols={[
        { key: 'title', label: 'Document', render: (x) => <>{x.title}<br /><span className="small muted">Version {x.version}</span></> },
        { key: 'published_at', label: 'Published', render: (x) => <>{d(x.published_at)}{x.published_by ? <span className="small muted"> by {x.published_by}</span> : null}</> },
        { key: 'requires_acceptance', label: 'Acceptance', render: (x) => x.requires_acceptance ? <Badge s="active">Required</Badge> : <span className="muted">Not asked</span> },
        { key: 'accepted', label: 'Accepted', num: true, render: (x) => <Link prefetch={false} className="link" href={`/admin/settings/terms?v=${x.id}#who`} data-testid="terms-accepted">{x.accepted}</Link> },
        { key: 'summary', label: 'What changed', render: (x) => <span className="small">{x.summary}</span> }]} />
    </Card>
    {shown && <Card title={`Who accepted ${shown.title}, version ${shown.version}`} id="who" testId="terms-who">
      <Table<Acceptance> rows={shown.acceptances ?? []} empty="Nobody has accepted it yet." rowKey={(x) => `${x.email}-${x.accepted_at}`} cols={[
        { key: 'name', label: 'Person', render: (x) => <>{x.name}<br /><span className="small muted">{x.email}</span></> },
        { key: 'accepted_at', label: 'Accepted', render: (x) => d(x.accepted_at) },
        { key: 'ip_address', label: 'IP address', render: (x) => x.ip_address ?? '' },
        { key: 'portal', label: 'Portal', render: (x) => x.portal ?? '' }]} />
    </Card>}
  </>);
}
