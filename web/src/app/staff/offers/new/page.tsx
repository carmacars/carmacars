import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { OfferComposer, type OcDraft } from '@/features/offers/OfferComposer';
import { UnfinishedRentals } from '@/features/supply/UnfinishedRentals';
import type { DraftRow } from '@/server/actions/supply';
import { door } from '@/server/door';
import type { OwnerDefaults } from '@/features/supply/OwnerChoice';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Send an offer', path: '/staff/offers/new', noindex: true, description: 'Send an offer to a customer without waiting for a request.' });

// Customer service and sales send an offer without a request (migration 0129): the rate sheet or a price typed with its
// reason, "I sourced this client" or "Entered for CarmaCars", open for 48 hours at most.
export default async function VaNewOffer({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const { user, aal } = await vaPage('/staff/offers/new', ['cs', 'sales']);
  const owner = await door<OwnerDefaults>(user.id, 'ops_read', 'owner_visibility_defaults', {}, aal).catch(() => null);
  const sp = await searchParams;
  const uuid = sp.draft && /^[0-9a-f-]{36}$/i.test(sp.draft) ? sp.draft : null;
  const [drafts, draft] = await Promise.all([door<DraftRow[]>(user.id, 'ops_read', 'drafts', { kind: 'offer' }, aal).catch(() => [] as DraftRow[]),
    uuid ? door<{ id: string; data: OcDraft; status: string } | null>(user.id, 'ops_read', 'draft_get', { id: uuid }, aal) : Promise.resolve(null)]);
  const open = draft && draft.status === 'open' ? draft : null;
  return (<>
    <PageHead title="Send an offer" />
    <p className="small muted" style={{ maxWidth: '52rem' }}>For a customer on the phone, by text or in person: no request needed. Already agreed and paid? Use <Link prefetch={false} className="link" href="/staff/bookings/new">Add a rental</Link>.</p>
    <UnfinishedRentals rows={drafts} base="/staff" current={open?.id} title="Unfinished offers" />
    <OfferComposer key={open?.id ?? 'new'} base="/staff" initialCar={sp.car ?? null} draft={open} owner={owner} />
  </>);
}
