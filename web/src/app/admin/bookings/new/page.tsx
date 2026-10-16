import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { ManualRentalForm } from '@/features/supply/ManualRentalForm';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add a rental', path: '/admin/bookings/new', noindex: true, description: 'Add a rental by hand: a phone or walk-in booking, or a past rental.' });

type Car = { id: string; name: string; plate: string | null; supply_type: string; bookable: boolean; retired: boolean; daily_rate_cents: number | null };

// Admin > Bookings > Add a rental (migration 0046).
export default async function AddRental() {
  const { user } = await page('/admin/bookings/new');
  const cars = await door<Car[]>(user.id, 'ops_read', 'manual_rental_vehicles');
  return (
    <>
      <PageHead kicker={<Link prefetch={false} className="link" href="/admin/bookings">Bookings</Link>} title="Add a rental" />
      <p className="small muted" style={{ maxWidth: '52rem' }}>For a rental taken by phone, at the counter, from Turo, a partner or an insurer. It is confirmed at once (or waits for the renter&apos;s online payment when you send a payment link), goes on the calendars, and the renter signs the agreement in their portal or on paper. A past rental is kept as completed for the history and the statements.</p>
      <div style={{ maxWidth: '60rem' }}><ManualRentalForm cars={cars} base="/admin" isAdmin /></div>
    </>
  );
}
