import 'server-only';
import { cookies } from 'next/headers';
import { auth } from '@/lib/auth';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { ipKey } from '@/lib/track/shared';
import { realUser } from '@/server/portal/data';
import { requestMeta } from '@/server/request';
import { DRAFT_COOKIE } from '@/features/owner/apply-schema';
import { CAPTURE_FORMS, cleanFields, type CaptureForm, type CaptureReply } from '@/features/capture/fields';

// Contact capture (migration 0090). What a person types into a form is saved as each field becomes valid; a new
// address opens an account at once. Only a brand-new address gives this browser an unverified session: a random token
// in the httpOnly cookie below (the database keeps its hash), bound to this browser's visitor id. It is NOT a sign-in:
// it shows only what this browser made (/my-request), and every money, signing and upload step needs the real sign-in
// that the emailed "Continue your request" link gives (it also confirms the email). See the change record for the
// threat model.
export const PENDING_COOKIE = 'cc-pending';
const SR = { role: 'service_role' as const };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const TOKEN = /^[0-9a-f]{64}$/;

const secure = () => env().APP_ENV !== 'local' || env().NEXT_PUBLIC_APP_URL.startsWith('https://');

export async function pendingToken(): Promise<string | null> {
  try { const t = (await cookies()).get(PENDING_COOKIE)?.value ?? null; return t && TOKEN.test(t) ? t : null; } catch { return null; }
}
export async function visitorCookie(): Promise<string | null> {
  try { const v = (await cookies()).get('cc_vid')?.value ?? null; return v && UUID.test(v) ? v : null; } catch { return null; }
}

export interface PendingView {
  ok: true; user_id: string; email: string; name: string; expires_at: string;
  drafts: Array<{ id: string; form_code: string; step: string | null; saved_at: string; car: string | null; car_name: string | null; from: string | null; to: string | null }>;
  bookings: Array<{ number: string; status: string; pickup_at: string; return_at: string; car: string }>;
  chats: Array<{ number: string; status: string; at: string }>;
}
/** This browser's unverified session, or null. */
export async function pendingView(): Promise<PendingView | null> {
  const t = await pendingToken();
  if (!t) return null;
  const r = (await rpc('server_capture_session_read', { p_token: t, p_visitor: (await visitorCookie()) ?? undefined }, SR).catch(() => null)) as unknown as PendingView | { ok: false } | null;
  return r && r.ok ? r : null;
}

/** A request sent from this browser during its unverified session becomes visible to it. */
export async function pendingAddBooking(bookingNumber: string): Promise<void> {
  const t = await pendingToken();
  if (t) await rpc('server_capture_session_add_booking', { p_token: t, p_number: bookingNumber }, SR).catch(() => undefined);
}

/** The form was sent: its captures are done (their leads and follow-ups close). */
export async function captureDone(form: CaptureForm, ref?: string | null): Promise<void> {
  const vid = await visitorCookie();
  if (vid) await rpc('server_capture_done', { p: { visitor_id: vid, form, ref: ref ?? '' } as unknown as Json }, SR).catch(() => undefined);
}

export async function endPending(): Promise<void> {
  const t = await pendingToken();
  if (t) await rpc('server_capture_session_end', { p_token: t }, SR).catch(() => undefined);
  try { (await cookies()).delete(PENDING_COOKIE); } catch { /* read-only context */ }
}

/** The sign-in account of an account the database opened: no password, email not confirmed, no email sent. */
export async function ensureSignIn(userId: string, email: string, name: string): Promise<void> {
  const a = await auth();
  if (!a.openForCapture) return;
  const r = await a.openForCapture(userId, email, name);
  if (r.ok || r.code === 'exists') await rpc('server_capture_sign_in_made', { p_user: userId }, SR).catch(() => undefined);
}

interface DbReply { ok: boolean; error?: string; saved?: boolean; state?: CaptureReply['state']; user_id?: string; email?: string; name?: string;
  make_sign_in?: boolean; session_token?: string | null; link_sent?: boolean; link_sent_before?: boolean; discard_user?: string | null }

/** One save from a form (the /api/capture route). */
export async function capture(input: { form?: unknown; ref?: unknown; draftToken?: unknown; vid?: unknown; name?: unknown; email?: unknown; phone?: unknown; page?: unknown }): Promise<CaptureReply> {
  const form = typeof input.form === 'string' && (CAPTURE_FORMS as readonly string[]).includes(input.form) ? (input.form as CaptureForm) : null;
  if (!form) return { ok: false };
  const f = cleanFields({ name: input.name, email: input.email, phone: input.phone });
  if (!f.name && !f.email && !f.phone) return { ok: true, state: null };
  const vid = (await visitorCookie()) ?? (typeof input.vid === 'string' && UUID.test(input.vid) ? input.vid : null);
  if (!vid) return { ok: false };
  const user = await realUser().catch(() => null);
  let ref = typeof input.ref === 'string' && UUID.test(input.ref) ? input.ref : '';
  let draftToken = typeof input.draftToken === 'string' && input.draftToken.length <= 200 ? input.draftToken : null;
  if (form === 'owner_application' && !user) {
    // the owner application keeps its draft token in an httpOnly cookie: the server finds the draft
    draftToken = (await cookies()).get(DRAFT_COOKIE)?.value ?? null;
    const d = draftToken ? (await rpc('load_form_draft', { p_form_code: 'owner_application', p_token: draftToken }, SR).catch(() => null)) as unknown as { draft_id?: string } | null : null;
    ref = d?.draft_id ?? '';
  }
  const meta = await requestMeta();
  const r = (await rpc('server_capture_contact', { p: {
    visitor_id: vid, form, ref, draft_token: draftToken, name: f.name, email: f.email, phone: f.phone,
    page: typeof input.page === 'string' ? input.page.slice(0, 300) : null, browser: true,
    ip_key: await ipKey(meta.ip, (env().SUPABASE_SERVICE_ROLE_KEY ?? 'local').slice(-24)).catch(() => null),
    session_token: await pendingToken(), signed_in: user?.id ?? null
  } as unknown as Json }, SR)) as unknown as DbReply;
  if (!r.ok) return { ok: false, rateLimited: r.error === 'rate_limited' };
  const a = await auth();
  if (r.discard_user && a.deleteAccount) await a.deleteAccount(r.discard_user).catch(() => undefined);
  if (r.make_sign_in && r.user_id && r.email) await ensureSignIn(r.user_id, r.email, r.name ?? r.email).catch(() => undefined);
  if (r.discard_user && !r.session_token) (await cookies()).delete(PENDING_COOKIE);
  if (r.session_token) {
    (await cookies()).set(PENDING_COOKIE, r.session_token, { httpOnly: true, sameSite: 'lax', secure: secure(), path: '/', maxAge: 30 * 86400 });
  }
  return { ok: true, state: r.state ?? null, linkSent: Boolean(r.link_sent), linkSentBefore: Boolean(r.link_sent_before) };
}

/** An address whose sign-in capture opened (no password, not confirmed): the sign-up and the owner application send
 *  the link to choose a password (it confirms the email) instead of refusing "an account already exists". */
export async function passwordLinkForCaptured(userId: string, email: string, redirectTo: string): Promise<boolean> {
  const unconfirmed = (await rpc('server_capture_unconfirmed', { p_user: userId }, SR).catch(() => false)) as unknown as boolean;
  if (!unconfirmed) return false;
  await (await auth()).requestPasswordReset(email, redirectTo);
  return true;
}

/** The browser that opened this brand-new account (its unverified session) chooses a password in the sign-up or the
 *  owner application: set it and send the usual confirmation link, as a sign-up would. Only for that browser's account. */
export async function claimPendingAccount(userId: string, email: string, password: string): Promise<boolean> {
  const v = await pendingView();
  if (!v || v.user_id !== userId || v.email.toLowerCase() !== email.trim().toLowerCase()) return false;
  const a = await auth();
  if (!a.claimForCapture) return false;
  const r = await a.claimForCapture(userId, email, password);
  return r.ok;
}
