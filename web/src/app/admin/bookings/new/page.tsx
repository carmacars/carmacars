import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { ManualRentalForm, type MrDraft } from '@/features/supply/ManualRentalForm';
import { UnfinishedRentals } from '@/features/supply/UnfinishedRentals';
import type { DraftRow } from '@/server/actions/supply';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Add a rental', path: '/admin/bookings/new', noindex: true, description: 'Add a rental by hand: a phone or walk-in booking, one already underway, or a past rental.' });

type Car = { id: string; name: string; plate: string | null; supply_type: string; bookable: boolean; retired: boolean; daily_rate_cents: number | null };

// Admin > Bookings > Add a rental (migration 0046).
export default async function AddRental({ searchParams }: { searchParams: Promise<{ draft?: string }> }) {
  const { user } = await page('/admin/bookings/new');
  const { draft: draftId } = await searchParams;
  const uuid = draftId && /^[0-9a-f-]{36}$/i.test(draftId) ? draftId : null;
  const [cars, drafts, draft] = await Promise.all([door<Car[]>(user.id, 'ops_read', 'manual_rental_vehicles'), door<DraftRow[]>(user.id, 'ops_read', 'drafts', { kind: 'rental' }),
    uuid ? door<{ id: string; data: MrDraft; held: boolean; quick: boolean; status: string } | null>(user.id, 'ops_read', 'draft_get', { id: uuid }) : Promise.resolve(null)]);
  const open = draft && draft.status === 'open' ? draft : null;
  return (
    <>
      <PageHead kicker={<Link prefetch={false} className="link" href="/admin/bookings">Bookings</Link>} title="Add a rental" />
      <p className="small muted" style={{ maxWidth: '52rem' }}>For a rental taken by phone, at the counter, from Turo, a partner or an insurer. The dates decide the rest: an upcoming rental is confirmed at once (or waits for the renter&apos;s online payment when you send a payment link); one already underway is recorded as on trip, with a task for anything still missing; one that has ended is kept as completed for the history and the statements. Every case goes on the calendars, and the renter signs the agreement in their portal or on paper.</p>
      {uuid && !open && <p className="alert alert--error" role="status"><span>That unfinished rental was already added or discarded.</span></p>}
      <div className="stack" style={{ maxWidth: '60rem' }}><UnfinishedRentals rows={drafts} base="/admin" current={open?.id} />
        <ManualRentalForm key={open?.id ?? 'new'} cars={cars} base="/admin" isAdmin draft={open} /></div>
    </>
  );
}
