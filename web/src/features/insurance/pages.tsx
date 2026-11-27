import { notFound } from 'next/navigation';
import { door } from '@/server/door';
import { InsuranceList, type InsBase, type InsList } from './InsuranceList';
import { InsuranceRental, type InsRental } from './InsuranceRental';
import { NewInsuranceRental, type InsDraft } from './NewInsuranceRental';
import { DraftGone } from './DraftGone';

// The three pages of Insurance replacements (5120), shared by Admin and the staff portal (Finance, customer service): each
// route checks its portal first, then reads through the staff door, which checks the person again.
type Who = { userId: string; aal?: 'aal1' | 'aal2' | null };
const one = (v: string | string[] | undefined) => (typeof v === 'string' ? v : undefined);

export async function ListPage({ who, base, sp }: { who: Who; base: InsBase; sp: Record<string, string | string[] | undefined> }) {
  const s = { q: one(sp.q), stage: one(sp.stage), aging: /^\d{1,3}$/.test(one(sp.aging) ?? '') ? one(sp.aging) : undefined, insurer: one(sp.insurer) };
  const data = await door<InsList>(who.userId, 'ops_read', 'insurer_rentals', s, who.aal);
  return <InsuranceList data={data} base={base} sp={s} />;
}

export async function RentalPage({ who, base, number, added }: { who: Who; base: InsBase; number: string; added: boolean }) {
  if (!/^[A-Za-z]{2,4}-\d{3,8}$/.test(number)) notFound();
  const x = await door<InsRental>(who.userId, 'ops_read', 'insurer_rental', { booking: number }, who.aal).catch((e: unknown) => {
    if (e instanceof Error && /not billed to an insurer|booking: the booking number/.test(e.message)) return null;
    throw e;
  });
  if (!x) notFound();
  return <InsuranceRental x={x} base={base} added={added} />;
}

type Car = { id: string; name: string; plate: string | null; retired: boolean };
type DraftGet = { id: string; data: InsDraft['data']; status: string; booking_number: string | null; closed_by: string | null; finished_at: string | null } | null;
export async function NewPage({ who, base, draftId }: { who: Who; base: InsBase; draftId: string | undefined }) {
  const uuid = draftId && /^[0-9a-f-]{36}$/i.test(draftId) ? draftId : null;
  const [cars, list, draft] = await Promise.all([door<Car[]>(who.userId, 'ops_read', 'manual_rental_vehicles', {}, who.aal),
    door<InsList & { insurers: Array<{ id: string; name: string }> }>(who.userId, 'ops_read', 'insurer_rentals', { limit: 1 }, who.aal),
    uuid ? door<DraftGet>(who.userId, 'ops_read', 'draft_get', { id: uuid }, who.aal) : Promise.resolve(null)]);
  const open = draft && draft.status === 'open' ? { id: draft.id, data: draft.data } : null;
  return (<>
    <h1 className="d3">Add an insurance replacement</h1>
    <p className="small muted">Only the renter&apos;s name, the insurer and claim, and the dates are needed. Everything else can follow, and the invoice is made on the rental&apos;s page.</p>
    {uuid && !open ? <DraftGone draft={draft} base={base} /> : null}
    <NewInsuranceRental key={open?.id ?? 'new'} cars={cars} insurers={list.insurers} base={base} draft={open} />
  </>);
}
