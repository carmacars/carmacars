import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { siteUrl } from '@/lib/site';
import { PageHead } from '@/features/admin/ui';
import { IncidentCards } from '@/features/incident-cards/IncidentCards';
import { PrintButton } from '@/features/incident-cards/PrintButton';
import type { CardData } from '@/features/incident-cards/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Incident cards', path: '/staff/vehicles/incident-cards', noindex: true, description: 'Print the incident card for a car or for every car.' });

// Release 34 (migration 0813): the same card for Fleet. The fleet insurance policy is set by an Admin.
export default async function StaffIncidentCards({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const sp = await searchParams;
  const { user } = await vaPage('/staff/vehicles/incident-cards', ['fleet']);
  const car = sp.car && /^[0-9a-f-]{36}$/.test(sp.car) ? sp.car : null;
  const data = await door<CardData>(user.id, 'ops_read', 'incident_cards', car ? { vehicle_id: car } : {}, undefined);
  return (
    <>
      <PageHead title="Incident cards" kicker={<Link prefetch={false} className="link" href="/staff/cars">Cars</Link>} purpose="Print on Letter paper, two cards a page with crop marks, then laminate and put one in each car.">
        <PrintButton label={car ? 'Print this car' : 'Print all cars'} testId="print-cards" />
        {car ? <Link prefetch={false} className="btn btn--ghost btn--sm" href="/staff/vehicles/incident-cards" data-testid="cards-all-link">All cars</Link> : null}
      </PageHead>
      {!data.policy && <p className="small" role="status">The fleet insurance policy is not set yet: an Admin adds it on the Admin incident cards page. The cards print without the slip until then.</p>}
      <IncidentCards data={data} site={siteUrl()} docBase="/staff/documents" />
    </>
  );
}
