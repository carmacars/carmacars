import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { OfferComposer, type OcDraft } from '@/features/offers/OfferComposer';
import { UnfinishedRentals } from '@/features/supply/UnfinishedRentals';
import type { DraftRow } from '@/server/actions/supply';
import { door } from '@/server/door';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Send an offer', path: '/admin/offers/new', noindex: true, description: 'Send an offer to a customer without waiting for a request.' });

// Admin > Bookings > Send an offer (migration 0129): no request needed. The same request and offer the website makes.
export default async function NewOffer({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const { user } = await page('/admin/offers/new');
  const sp = await searchParams;
  const uuid = sp.draft && /^[0-9a-f-]{36}$/i.test(sp.draft) ? sp.draft : null;
  const [drafts, draft] = await Promise.all([door<DraftRow[]>(user.id, 'ops_read', 'drafts', { kind: 'offer' }).catch(() => [] as DraftRow[]),
    uuid ? door<{ id: string; data: OcDraft; status: string } | null>(user.id, 'ops_read', 'draft_get', { id: uuid }) : Promise.resolve(null)]);
  const open = draft && draft.status === 'open' ? draft : null;
  return (<>
    <PageHead kicker={<Link prefetch={false} className="link" href="/admin/bookings">Bookings</Link>} title="Send an offer" />
    <p className="small muted" style={{ maxWidth: '52rem' }}>For a customer on the phone, by text or in person: no request needed. The renter gets the offer link, approves, signs and pays (or you record the payment); then it is on the calendar. For a rental that is already agreed and paid, use <Link prefetch={false} className="link" href="/admin/bookings/new">Add a rental</Link>.</p>
    <UnfinishedRentals rows={drafts} base="/admin" current={open?.id} title="Unfinished offers" />
    <OfferComposer key={open?.id ?? 'new'} base="/admin" initialCar={sp.car ?? null} draft={open} />
  </>);
}
