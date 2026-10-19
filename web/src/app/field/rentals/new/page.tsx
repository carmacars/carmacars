import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { ManualRentalForm } from '@/features/supply/ManualRentalForm';
import { homeAddressOf } from '@/features/staff/HomeAddress';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add a rental', path: '/field/rentals/new', noindex: true, description: 'Add a rental for a renter you found.' });

type Car = { id: string; name: string; plate: string | null; supply_type: string; bookable: boolean; retired: boolean; daily_rate_cents: number | null };

// Field staff add a rental (migration 0058): the renter's details typed, the rate sheet or a price typed with its reason,
// paid by a payment link or the renter's saved card (field staff take no payment themselves), and the choice "I sourced
// this client" or "Entered for CarmaCars".
export default async function FieldAddRental() {
  const { user } = await requireStaff('field', '/field/rentals/new');
  const [cars, home] = await Promise.all([door<Car[]>(user.id, 'ops_read', 'manual_rental_vehicles', {}), homeAddressOf(user.id, 'field')]);
  return (
    <div className="stack">
      <h1 className="d3">Add a rental</h1>
      <p className="small muted">For a renter you met or who called you. The renter gets an email to sign and pay online; you never take payment yourself.</p>
      {home.missing ? <p className="alert alert--error" role="status" data-testid="rental-needs-address"><span>Add your home address at the top of the page before you add a rental.</span></p>
        : <ManualRentalForm cars={cars} base="/field" isAdmin={false} />}
    </div>
  );
}
