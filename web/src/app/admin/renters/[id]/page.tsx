import Link from 'next/link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Badge, BookingLink, Card, Kv, PageHead, Table, d, t } from '@/features/admin/ui';
import { VisitorTimeline, type TimelineData } from '@/features/live/VisitorTimeline';
import { PhoneTimeline } from '@/features/phone/PhoneTimeline';
import { ReachCard } from '@/features/admin/ReachCard';
import type { Reach } from '@/features/phone/alerts';
import type { PhoneTimelineData } from '@/features/phone/client';
import { RenterEdit, type RenterForm } from '@/features/money/RenterEdit';
import { RenterMerge, type DuplicateRow } from '@/features/money/RenterMerge';
import { door } from '@/server/door';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Renter', path: '/admin/renters', noindex: true, description: 'One renter: details, bookings and visits on the site.' });

type R = { id: string; name: string; email: string | null; mobile: string | null; identity_status: string; created_at: string; city: string | null; is_blocked: boolean;
  bookings: Array<{ number: string; status: string; pickup_at: string; return_at: string; car: string }>; timeline: TimelineData;
  email_confirmed?: boolean; has_sign_in?: boolean; account_opened_from_form?: boolean; account_closed?: boolean;
  captured?: Array<{ form: string; name: string | null; email: string | null; phone: string | null; at: string; done: boolean }> };

// People > Renters > a renter (migration 0060): the record, the bookings, and what they looked at on the site and their chats.
export default async function Renter({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read, user } = await page(`/admin/renters/${id}`);
  const [r, calls] = await Promise.all([read<R>('renter_live', { renter_id: id }).catch(() => null), read<PhoneTimelineData>('phone_timeline', { renter_id: id }).catch(() => null)]);
  const reach = await read<Reach>('notify_reach', { renter_id: id }).catch(() => null);
  if (!r) notFound();
  // correct the renter's details (0132)
  const rf = await door<RenterForm>(user.id, 'ops_read', 'renter_edit_form', { renter: id }).catch(() => null);
  // the same person entered twice (0145)
  const dupes = await door<DuplicateRow[]>(user.id, 'ops_read', 'renter_duplicates', { renter: id }).catch(() => [] as DuplicateRow[]);
  return (
    <>
      <PageHead title={r.name} kicker="Renter"><Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/renters">All renters</Link></PageHead>
      <div className="ad-cols ad-cols--2">
        <div className="stack">
          {rf && <RenterEdit x={rf} />}
          <RenterMerge renterId={id} name={r.name} rows={dupes} />
          <Card title="Details"><Kv rows={[['Email', <span key="e">{r.email ?? ''}{r.has_sign_in && !r.email_confirmed && <> <span className="ad-b ad-b--amber" data-testid="email-not-confirmed">Email not confirmed</span></>}</span>], ['Phone', r.mobile ?? ''], ['City', r.city ?? ''], ['Identity', <Badge key="i" s={r.identity_status} />], ['Blocked', r.is_blocked ? 'Yes' : 'No'], ['Since', d(r.created_at)]]} /></Card>
          {!!r.captured?.length && (
            <Card title="Typed into forms" testId="renter-captured">
              {r.account_opened_from_form && <p className="small muted">The account was opened from a form{r.account_closed ? ' and closed: the email was not confirmed in time' : ''}. It cannot accept an offer, sign or pay until the email is confirmed.</p>}
              <Table rows={r.captured} rowKey={(c) => c.form + c.at} cols={[{ key: 'form', label: 'Form' }, { key: 'name', label: 'Name' }, { key: 'email', label: 'Email' }, { key: 'phone', label: 'Phone' },
                { key: 'at', label: 'Typed', render: (c) => t(c.at) }, { key: 'done', label: 'Sent', render: (c) => (c.done ? 'Yes' : 'Not sent') }]} />
            </Card>)}
          <Card title="Bookings"><Table rows={r.bookings} rowKey={(b) => b.number} empty="No bookings yet." cols={[{ key: 'number', label: 'Booking', render: (b) => <BookingLink n={b.number} /> },
            { key: 'car', label: 'Car' }, { key: 'status', label: 'Status', render: (b) => <Badge s={b.status} /> }, { key: 'pickup_at', label: 'Pickup', render: (b) => t(b.pickup_at) }]} /></Card>
        </div>
        <div className="stack">
          <ReachCard reach={reach} who={{ renter_id: id }} />
          <Card title="Calls and texts" testId="renter-calls"><PhoneTimeline t={calls} inbox="/admin/chat" /></Card>
          <Card title="On the site" testId="renter-visits"><VisitorTimeline t={r.timeline} chatBase="/admin/chat" /></Card>
        </div>
      </div>
    </>
  );
}
