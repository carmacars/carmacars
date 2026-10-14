import 'server-only';
import { notFound, redirect } from 'next/navigation';
import { auth, type SessionUser } from '@/lib/auth';
import { rpc } from '@/lib/db/repo';
import type { BookingSummary, Doc, MyBooking, Notice, NoticePref, Profile } from '@/features/portal/types';

// Reads for the renter portal. Every read runs as the signed-in user (role authenticated), so
// row-level security decides what comes back (migration 0028); nothing here uses the service role.
export async function currentUser(): Promise<SessionUser | null> {
  return (await auth()).currentUser();
}

export async function requireUser(next = '/account'): Promise<SessionUser> {
  const u = await currentUser();
  if (!u) redirect(`/sign-in?next=${encodeURIComponent(next)}`);
  return u;
}

const as = (u: SessionUser) => ({ userId: u.id, role: 'authenticated' as const });

export async function myBookings(u: SessionUser): Promise<BookingSummary[]> {
  return ((await rpc('my_bookings', {}, as(u))) ?? []) as unknown as BookingSummary[];
}

export async function findBooking(u: SessionUser, number: string): Promise<MyBooking | null> {
  if (!/^[A-Z]{1,4}-[0-9A-Z]{1,12}$/.test(number)) return null;
  return (await rpc('my_booking', { p_number: number }, as(u))) as unknown as MyBooking | null;
}

/** The booking of the signed-in renter, or a 404 (another renter's number reads as not found). */
export async function myBooking(number: string, sub = ''): Promise<{ user: SessionUser; b: MyBooking }> {
  const n = decodeURIComponent(number);
  const user = await requireUser(`/account/bookings/${encodeURIComponent(n)}${sub ? `/${sub}` : ''}`);
  const b = await findBooking(user, n);
  if (!b) notFound();
  return { user, b };
}

export async function myProfile(u: SessionUser): Promise<Profile> {
  return (await rpc('my_profile', {}, as(u))) as unknown as Profile;
}
export async function myDocuments(u: SessionUser): Promise<Doc[]> {
  return ((await rpc('my_documents', {}, as(u))) ?? []) as unknown as Doc[];
}
export async function myNotifications(u: SessionUser, limit = 50): Promise<Notice[]> {
  return ((await rpc('my_notifications', { p_limit: limit, p_unread_only: false }, as(u))) ?? []) as unknown as Notice[];
}
export async function myNotificationPrefs(u: SessionUser): Promise<NoticePref[]> {
  return ((await rpc('my_notification_preferences', {}, as(u))) ?? []) as unknown as NoticePref[];
}
export async function cancellationPreview(u: SessionUser, bookingId: string) {
  return (await rpc('my_cancellation_preview', { p_booking: bookingId }, as(u))) as unknown as CancellationPreview;
}

export interface CancellationPreview {
  tier: string; status: string; start_at: string; can_cancel: boolean; refund_bps: number; received_at: string; refund_cents: number;
  refund_due_by: string | null; booking_number: string; non_refundable: boolean; retained_cents: number; booking_made_at: string;
  total_paid_cents: number; deposit_returned_cents: number; deposit_hold_to_release: boolean; reason?: string | null; message?: string | null;
}

export interface ReviewState {
  can_review: boolean; status: string;
  review: { rating: number; title: string | null; body: string | null; status: 'pending' | 'published' | 'hidden'; staff_reply: string | null; created_at: string; publish_consent: boolean } | null;
}
/** The booking's review for its renter (public.renter_review_state of 0034 checks the renter again). */
export async function reviewState(u: SessionUser, bookingId: string): Promise<ReviewState> {
  return (await rpc('renter_review_state', { p_booking: bookingId, p_by: u.id }, { role: 'service_role' })) as unknown as ReviewState;
}
