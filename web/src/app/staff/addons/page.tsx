import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { AddonsAdmin, type AddonsData } from '@/features/addons/AddonsAdmin';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add-ons', path: '/staff/addons', noindex: true, description: 'Add-ons and their stock.' });

// Fleet > Add-ons (migration 0066): the catalogue with what is booked, and the stock of physical items (baby seats,
// umbrellas, chargers). Prices and rules are set by an Admin.
export default async function Addons() {
  const { read } = await vaPage('/staff/addons', ['fleet']);
  const data = await read<AddonsData>('addons');
  return (<>
    <PageHead title="Add-ons" kicker="Stock of the items we put in the car" />
    <p className="small muted">Set how many of each item we have. Bookings over the same dates count against it, so renters cannot ask for more than we have. Prices and rules are set by an Admin.</p>
    <AddonsAdmin data={data} />
  </>);
}
