import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { ManualRentalForm } from '@/features/supply/ManualRentalForm';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add a rental', path: '/va/bookings/new', noindex: true, description: 'Add a rental taken by phone or at the counter.' });

type Car = { id: string; name: string; plate: string | null; supply_type: string; bookable: boolean; retired: boolean; daily_rate_cents: number | null };

// Customer service and Sales: add a rental by hand (migration 0046), at the rate-sheet price, with the promo codes and
// the ways of payment Program settings allow (Admins decide a clash, a price typed by hand and past rentals).
export default async function VaAddRental() {
  const { user, aal } = await vaPage('/va/bookings/new', ['cs', 'sales']);
  const cars = await door<Car[]>(user.id, 'ops_read', 'manual_rental_vehicles', {}, aal);
  return (
    <>
      <PageHead title="Add a rental" />
      <p className="small muted" style={{ maxWidth: '52rem' }}>For a rental taken by phone or at the counter. The price comes from the rate sheet. When the car is not free, choose other dates or another car, or ask an Admin.</p>
      <div style={{ maxWidth: '60rem' }}><ManualRentalForm cars={cars} base="/va" isAdmin={false} /></div>
    </>
  );
}
