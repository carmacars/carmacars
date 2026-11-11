import { IntentCard } from '@/features/intent/IntentCard';
import type { Intent } from '@/features/intent/model';
import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Badge, BookingLink, Card, Kv, PageHead, Table, d, t } from '@/features/admin/ui';
import { ReachCard } from '@/features/admin/ReachCard';
import type { Reach } from '@/features/phone/alerts';
import { RenterEdit, type RenterForm } from '@/features/money/RenterEdit';
import { RenterMerge, RenterMerges, type DuplicateRow, type MergeRow } from '@/features/money/RenterMerge';
import { door } from '@/server/door';
import { BookingConversation } from '@/features/messages/BookingConversation';
import type { Conversation } from '@/features/messages/email-choices';
import { NameChangeCard } from '@/features/admin/NameChangeCard';
import { nameChangesFor } from '@/server/self-profile';
import { ContactButtons } from '@/features/phone/QuoButtons';
import { RenterNotes } from '@/features/caller/RenterNotes';
import type { NotesRead } from '@/features/caller/model';
import { ActivityLog } from '@/features/activity/ActivityLog';
import { activityQuery, readParams, type ActivityPage } from '@/features/activity/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Renter', path: '/admin/renters', noindex: true, description: 'One renter: details, bookings and visits on the site.' });

type R = { id: string; name: string; email: string | null; mobile: string | null; identity_status: string; created_at: string; city: string | null; is_blocked: boolean;
  bookings: Array<{ number: string; status: string; pickup_at: string; return_at: string; car: string }>;
  email_confirmed?: boolean; has_sign_in?: boolean; account_opened_from_form?: boolean; account_closed?: boolean;
  captured?: Array<{ form: string; name: string | null; email: string | null; phone: string | null; at: string; done: boolean }> };

// People > Renters > a renter (migration 0060): the record, the bookings, and what they looked at on the site and their chats.
export default async function Renter({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ id }, sp] = await Promise.all([params, searchParams]);
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { read, user } = await page(`/admin/renters/${id}`);
  // r35 (0850): one Activity log of everything about the renter, in place of the calls, visits and messages cards
  const [r, activity] = await Promise.all([read<R>('renter_live', { renter_id: id }).catch(() => null),
    read<ActivityPage>('renter_activity', { renter_id: id, ...readParams(activityQuery(sp)) }).catch(() => null)]);
  const [reach, notes, nameChanges] = await Promise.all([read<Reach>('notify_reach', { renter_id: id }).catch(() => null), read<NotesRead>('renter_notes', { renter_id: id }).catch(() => null), nameChangesFor(user.id, { renter_id: id })]);
  if (!r) notFound();
  // correct the renter's details (0132)
  const rf = await door<RenterForm>(user.id, 'ops_read', 'renter_edit_form', { renter: id }).catch(() => null);
  // the same person entered twice (0148)
  const dupes = await door<DuplicateRow[]>(user.id, 'ops_read', 'renter_duplicates', { renter: id }).catch(() => [] as DuplicateRow[]);
  // r35 (0955): the merges of this renter, automatic or by staff, with Undo for an Admin
  const merges = await door<{ admin: boolean; rows: MergeRow[] }>(user.id, 'ops_read', 'renter_merges', { renter: id }).catch(() => ({ admin: false, rows: [] as MergeRow[] }));
  // r35 part C (1506): the renter's intent signals
  const intent = await door<Intent | null>(user.id, 'ops_read', 'intent', { renter: id }).catch(() => null);
  // Email the renter (0187): an email goes with one of their bookings (the latest unless another is chosen), so it is kept
  // on that booking's messages and the renter can answer it in their account
  const latest = [...r.bookings].sort((a, b) => (a.pickup_at < b.pickup_at ? 1 : -1))[0];
  const chosen = r.bookings.find((b) => b.number === sp.booking) ?? latest;
  const conv = chosen ? await door<Conversation>(user.id, 'ops_read', 'booking_conversation', { booking: chosen.number }).catch(() => null) : null;
  return (
    <>
      <PageHead title={r.name} kicker="Renter"><Link prefetch={false} className="btn btn--ghost btn--sm" href="/admin/renters">All renters</Link></PageHead>
      <div className="ad-cols ad-cols--2">
        <div className="stack">
          <IntentCard intent={intent} />
          <NameChangeCard items={nameChanges} refresh={[`/admin/renters/${id}`]} />
          {rf && <RenterEdit x={rf} />}
          <RenterMerge renterId={id} name={r.name} rows={dupes} />
          <RenterMerges rows={merges.rows} admin={merges.admin} />
          <Card title="Details"><Kv rows={[['Email', <span key="e">{r.email ?? ''}{r.has_sign_in && !r.email_confirmed && <> <span className="ad-b ad-b--amber" data-testid="email-not-confirmed">Email not confirmed</span></>}</span>], ['Phone', r.mobile ? <ContactButtons key="p" phone={r.mobile} name={r.name} look="link" inbox="/admin/visitors?view=chat" testId="renter-phone">{r.mobile}</ContactButtons> : ''], ['City', r.city ?? ''], ['Identity', <Badge key="i" s={r.identity_status} />], ['Blocked', r.is_blocked ? 'Yes' : 'No'], ['Since', d(r.created_at)]]} /></Card>
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
        </div>
      </div>
      {/* r35 (0850): everything in one log; the note box (r34, 0800) above it, Email, Call and Text on it */}
      <ActivityLog data={activity} base={`/admin/renters/${id}`} sp={sp} emailHref={chosen ? `/admin/renters/${id}${sp.booking ? `?booking=${encodeURIComponent(sp.booking)}` : ''}#email` : null}
        chatBase="/admin/visitors?view=chat" inbox="/admin/visitors?view=chat" phone={r.mobile} name={r.name} booking={chosen?.number ?? null} canRemoveNotes={!!notes?.can_remove}>
        <div data-testid="renter-notes-card">{notes ? <RenterNotes renterId={id} initial={notes.notes} canRemove={notes.can_remove} formOnly /> : <p className="small muted">The notes could not be read. Reload the page.</p>}</div>
      </ActivityLog>
      <section className="stack" id="email" data-testid="renter-email">
        <h2 className="d4">Email the renter</h2>
        {r.bookings.length > 1 && <p className="small">About booking: {r.bookings.map((b, i) => <span key={b.number}>{i ? ' · ' : ''}{b.number === chosen?.number ? <b>{b.number}</b> : <Link prefetch={false} className="link" href={`/admin/renters/${id}?booking=${encodeURIComponent(b.number)}#email`}>{b.number}</Link>}</span>)}</p>}
        {conv ? <BookingConversation c={conv} refresh={[`/admin/renters/${id}`]} composeOnly />
          : <p className="small muted">{r.bookings.length ? 'The messages could not be read. Reload the page.' : 'An email goes with one of the renter\u2019s bookings, so they can answer it in their account. This renter has no booking yet: call them, or answer their request or chat.'}</p>}
      </section>
    </>
  );
}
