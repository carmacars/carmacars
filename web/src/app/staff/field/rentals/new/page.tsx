import { pageMeta } from '@/features/seo/meta';
import { door, requireStaff } from '@/server/door';
import { ManualRentalForm, type MrDraft } from '@/features/supply/ManualRentalForm';
import { UnfinishedRentals } from '@/features/supply/UnfinishedRentals';
import type { DraftRow } from '@/server/actions/supply';
import { homeAddressOf } from '@/features/staff/HomeAddress';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add a rental', path: '/staff/field/rentals/new', noindex: true, description: 'Add a rental for a renter you found.' });

type Car = { id: string; name: string; plate: string | null; supply_type: string; bookable: boolean; retired: boolean; daily_rate_cents: number | null };

// Field staff add a rental (migration 0058): the renter's details typed, the rate sheet or a price typed with its reason,
// paid by a payment link or the renter's saved card (field staff take no payment for it themselves), and the choice "I sourced
// this client" or "Entered for CarmaCars".
export default async function FieldAddRental({ searchParams }: { searchParams: Promise<{ draft?: string }> }) {
  const { user } = await requireStaff('field', '/staff/field/rentals/new');
  const { draft: draftId } = await searchParams;
  const uuid = draftId && /^[0-9a-f-]{36}$/i.test(draftId) ? draftId : null;
  const [cars, home, drafts, draft] = await Promise.all([door<Car[]>(user.id, 'ops_read', 'manual_rental_vehicles', {}), homeAddressOf(user.id, 'field'),
    door<DraftRow[]>(user.id, 'ops_read', 'drafts', { kind: 'rental', mine: true }),
    uuid ? door<{ id: string; data: MrDraft; held: boolean; quick: boolean; status: string } | null>(user.id, 'ops_read', 'draft_get', { id: uuid }) : Promise.resolve(null)]);
  const open = draft && draft.status === 'open' ? draft : null;
  return (
    <div className="stack">
      <h1 className="d3">Add a rental</h1>
      <p className="small muted">For a renter you met or who called you, including one who already has the car (enter the pickup as when it left). The renter gets an email to sign and pay online; you take no payment for it yourself.</p>
      {home.missing ? <p className="alert alert--error" role="status" data-testid="rental-needs-address"><span>Add your home address at the top of the page before you add a rental.</span></p>
        : <><UnfinishedRentals rows={drafts} base="/staff/field" current={open?.id} /><ManualRentalForm key={open?.id ?? 'new'} cars={cars} base="/staff/field" isAdmin={false} draft={open} /></>}
    </div>
  );
}
