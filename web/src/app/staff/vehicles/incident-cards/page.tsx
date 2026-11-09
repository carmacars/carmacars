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
export const metadata = pageMeta({ title: 'Incident cards', path: '/staff/vehicles/incident-cards', noindex: true, description: 'Print the incident card that goes in every car.' });

// Release 34 (migration 0813): the same card for Fleet (one generic card since 1150). The fleet insurance policy is set by an Admin.
export default async function StaffIncidentCards() {
  const { user } = await vaPage('/staff/vehicles/incident-cards', ['fleet']);
  const data = await door<CardData>(user.id, 'ops_read', 'incident_cards', { vehicle_id: '00000000-0000-0000-0000-000000000000' }, undefined);
  return (
    <>
      <PageHead title="Incident cards" kicker={<Link prefetch={false} className="link" href="/staff/cars">Cars</Link>} purpose="One card for every car: print on Letter paper (two cards a page, cut at the crop marks), as many copies as you need, then laminate and put one in each car. Its QR code opens the renter's digital incident card.">
        <PrintButton label="Print the cards" testId="print-cards" />
      </PageHead>
      {!data.policy && <p className="small" role="status">The fleet insurance policy is not set yet: an Admin adds it on the Admin incident cards page. The cards print without the slip until then.</p>}
      <IncidentCards data={data} site={siteUrl()} docBase="/staff/documents" />
    </>
  );
}
