import Link from '@/components/Link';
import { ContactButtons } from '@/features/phone/QuoButtons';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { door } from '@/server/door';
import { OnboardingChecklist } from '@/features/onboarding/OnboardingChecklist';
import { PrepPanel, type PrepList } from '@/features/field-portal/FleetPanels';
import { OnboardingPhotos } from '@/features/onboarding/OnboardingPhotos';
import { GovernmentForms } from '@/features/onboarding/GovernmentForms';
import { VinList } from '@/features/onboarding/VinList';
import { onboardingData } from '@/server/onboarding';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner', path: '/staff/owners', noindex: true, description: 'One owner: the onboarding checklist, the photos, the government forms and adding cars.' });

// r34: one owner for customer service and fleet, the same parts as the Admin's owner page (src/app/admin/owners/[id]):
// the Onboarding checklist, the onboarding photos (replace, remove, approve), the government forms and Add cars from a
// VIN list. Owner terms, fees and invoices stay with an Admin.
export default async function StaffOwner({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { user } = await vaPage(`/staff/owners/${id}`, ['cs', 'fleet']);
  const ob = await onboardingData(user.id, 'va_read', { owner_id: id });
  if (!ob.overview) notFound();
  const o = ob.overview.owner;
  const here = [`/staff/owners/${id}`];
  const cars = ob.overview.cars.map((c) => ({ vehicle_id: c.vehicle_id, name: c.name }));
  // r35 part X (0930): field staff prep each car joining the fleet; Fleet gives it and sees its progress (customer service does not)
  const preps = await Promise.all(ob.overview.cars.map(async (c) => [c, await door<PrepList>(user.id, 'ops_read', 'field_prep', { vehicle: c.vehicle_id, _va: 'fleet' }).catch(() => null)] as const));
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/staff/owners">Owners</Link>} title={o.name}>
      <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/staff/owners/add-car?owner=${id}`} data-testid="owner-add-car">Add another car</Link></PageHead>
    <OnboardingChecklist data={ob.overview} />
    {preps.map(([c, x]) => x && <PrepPanel key={c.vehicle_id} p={x} vehicle={{ id: c.vehicle_id, name: c.name }} title={`Onboarding prep: ${c.name}`} />)}
    <div className="pt-split">
      <div className="stack-lg">
        <OnboardingPhotos photos={ob.photos} ownerId={id} viewer="staff" refresh={here} cars={cars} />
        <GovernmentForms data={ob.forms} viewer="staff" refresh={here} />
        {!o.fleet_supplier && <details className="pt-card" id="add-vins"><summary className="link">Add cars from a list of VINs</summary><VinList ownerId={id} viewer="staff" refresh={here} /></details>}
      </div>
      <aside className="pt-split__aside stack-lg">
        <section className="pt-card stack" id="send-link" aria-labelledby="so-c"><h2 className="d4" id="so-c">Contact the owner</h2>
          <p className="small">{o.has_account ? 'The owner signs in to the owner portal to finish their details and sign.' : 'No owner portal account yet: an Admin invites the owner from the Admin owner page.'}</p>
          <ul className="ad-list small">{o.email && <li><a className="link" href={`mailto:${o.email}`}>{o.email}</a></li>}{o.phone && <li><ContactButtons phone={o.phone} look="link" testId="owner-phone">{o.phone}</ContactButtons></li>}</ul></section>
      </aside>
    </div>
  </>);
}
