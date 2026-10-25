import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { ManualRentalForm, type MrDraft } from '@/features/supply/ManualRentalForm';
import { UnfinishedRentals } from '@/features/supply/UnfinishedRentals';
import type { DraftRow } from '@/server/actions/supply';
import type { OwnerDefaults } from '@/features/supply/OwnerChoice';
import { homeAddressOf } from '@/features/staff/HomeAddress';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add a rental', path: '/va/bookings/new', noindex: true, description: 'Add a rental taken by phone or at the counter.' });

type Car = { id: string; name: string; plate: string | null; supply_type: string; bookable: boolean; retired: boolean; daily_rate_cents: number | null };

// Every assistant function adds a rental by hand (migrations 0046 and 0058): the rate-sheet price or a price typed with
// its reason, the promo codes and the ways of payment Program settings allow, and the choice "I sourced this client" or
// "Entered for CarmaCars" (Admins decide a clash, the Deposit and past rentals). A rental already underway is added by anyone (0074).
export default async function VaAddRental({ searchParams }: { searchParams: Promise<{ draft?: string }> }) {
  const { user, aal } = await vaPage('/va/bookings/new');
  const { draft: draftId } = await searchParams;
  const uuid = draftId && /^[0-9a-f-]{36}$/i.test(draftId) ? draftId : null;
  const [cars, home, owner, drafts, draft] = await Promise.all([door<Car[]>(user.id, 'ops_read', 'manual_rental_vehicles', {}, aal), homeAddressOf(user.id, 'va'),
    door<OwnerDefaults>(user.id, 'ops_read', 'owner_visibility_defaults', {}, aal).catch(() => null),
    door<DraftRow[]>(user.id, 'ops_read', 'drafts', { kind: 'rental' }, aal),
    uuid ? door<{ id: string; data: MrDraft; held: boolean; quick: boolean; status: string } | null>(user.id, 'ops_read', 'draft_get', { id: uuid }, aal) : Promise.resolve(null)]);
  const open = draft && draft.status === 'open' ? draft : null;
  return (
    <>
      <PageHead title="Add a rental" />
      <p className="small muted" style={{ maxWidth: '52rem' }}>For a rental taken by phone, at the counter or from someone you know, including one already underway (enter the pickup as when the car left). The price comes from the rate sheet unless you type another with its reason. Say whether you sourced the client. When the car is not free, choose other dates or another car, or ask an Admin.</p>
      {home.missing ? <p className="alert alert--error" role="status" data-testid="rental-needs-address"><span>Add your home address at the top of the page before you add a rental.</span></p>
        : <div className="stack" style={{ maxWidth: '60rem' }}>{uuid && !open && <p className="alert alert--error" role="status"><span>That unfinished rental was already added or discarded.</span></p>}
          <UnfinishedRentals rows={drafts} base="/va" current={open?.id} />
          <ManualRentalForm key={open?.id ?? 'new'} cars={cars} base="/va" isAdmin={false} owner={owner} draft={open} /></div>}
    </>
  );
}
