import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { siteUrl } from '@/lib/site';
import { Card, PageHead } from '@/features/admin/ui';
import { Act } from '@/features/admin/Act';
import { IncidentCards } from '@/features/incident-cards/IncidentCards';
import { PrintButton } from '@/features/incident-cards/PrintButton';
import type { CardData } from '@/features/incident-cards/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Incident cards', path: '/admin/vehicles/incident-cards', noindex: true, description: 'Print the incident card for a car or for every car.' });

// Release 34 (migration 0813): the card for the visor or the glovebox: what to do in an accident or a breakdown, the support
// and roadside numbers from settings, a QR code to report it in the app, and the fleet insurance slip. ?car=<id> prints one car.
export default async function IncidentCardsPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { user } = await page('/admin/vehicles/incident-cards');
  const car = sp.car && /^[0-9a-f-]{36}$/.test(sp.car) ? sp.car : null;
  const data = await door<CardData>(user.id, 'ops_read', 'incident_cards', car ? { vehicle_id: car } : {});
  const choices = await door<Array<{ id: string; title: string; plate: string | null }>>(user.id, 'ops_read', 'fleet_policy_slip_choices', {}).catch(() => []);
  const p = data.policy;
  return (
    <>
      <PageHead title="Incident cards" kicker={<Link prefetch={false} className="link" href="/admin/vehicles">Vehicles</Link>} purpose="Print on Letter paper, two cards a page with crop marks, then laminate and put one in each car.">
        <PrintButton label={car ? 'Print this car' : 'Print all cars'} testId="print-cards" />
        {car ? <Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/vehicles/incident-cards" data-testid="cards-all-link">All cars</Link> : null}
      </PageHead>
      <Card title="Fleet insurance policy" testId="fleet-policy">
        <p className="small">{p ? <>On the card: {p.insurer_name}, policy {p.policy_number}, {p.effective_on} to {p.expires_on}{p.expired ? ' (expired: update it)' : ''}, named insured {p.named_insured}.{p.slip_document_id ? ' The uploaded slip is shown.' : ' No slip file is attached, so the fields are printed.'}</> : 'No policy is set yet: the card says to ask for the slip. Add it below.'} The card never shows a premium.</p>
        <Act ops action="fleet_policy_save" label={p ? 'Change the policy' : 'Add the policy'} variant="primary" title="Fleet insurance policy" submitLabel="Save" testId="fleet-policy-save" refresh={['/admin/vehicles/incident-cards']} done="Saved. The cards use it now."
          fields={[
            { name: 'insurer_name', label: 'Insurer', required: true, value: p?.insurer_name ?? '' },
            { name: 'policy_number', label: 'Policy number', required: true, value: p?.policy_number ?? '' },
            { name: 'effective_on', label: 'Effective', type: 'date', required: true, value: p?.effective_on ?? '' },
            { name: 'expires_on', label: 'Expires', type: 'date', required: true, value: p?.expires_on ?? '' },
            { name: 'named_insured', label: 'Named insured', value: p?.named_insured ?? '18122211 Canada Inc.' },
            { name: 'roadside_phone', label: 'Roadside number on the slip (optional)', type: 'tel', value: data.company.roadside_phone ?? '' },
            { name: 'claims_phone', label: 'Claims number (optional)', type: 'tel', value: p?.claims_phone ?? '' },
            { name: 'slip_document_id', label: 'Uploaded slip to print (optional)', type: 'select', value: p?.slip_document_id ?? '',
              options: [['', 'None: print the fields'], ...choices.map((c) => [c.id, `${c.title}${c.plate ? ` (${c.plate})` : ''}`] as [string, string])] }]} />
      </Card>
      <IncidentCards data={data} site={siteUrl()} docBase="/admin/documents" />
    </>
  );
}
