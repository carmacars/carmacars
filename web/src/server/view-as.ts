import 'server-only';
import { cache } from 'react';
import { cookies, headers } from 'next/headers';
import { auth, type SessionUser } from '@/lib/auth';
import { env } from '@/lib/env';
import { readToken } from '@/server/links';
import { ADMIN_AREA_HEADER, VIEW_AS_COOKIE } from '@/lib/security/view-as-guard';

// "View as": an Admin opens another person's portal, read only. The choice is a signed (LINK_SIGNING_KEY),
// httpOnly cookie that lasts 30 minutes and names the Admin who set it. It counts only while that same Admin is
// signed in and is still an Admin (checked again on every request, with two-step sign-in when it is required).
// Pages and reads then use the other person's identity (src/server/portal/data.ts currentUser, the database calls
// in src/lib/db/repo.ts); every write is refused: by the Worker entry for every POST outside /admin
// (src/lib/security/view-as-guard.ts), and here for any database call made for that person that is not a read.
export type ViewPortal = 'account' | 'owner' | 'va' | 'field' | 'investor';
export type VaFn = 'finance' | 'fleet' | 'cs' | 'sales';
export interface ViewAs { target: SessionUser & { name: string }; portal: ViewPortal; fn: VaFn | null; admin: SessionUser }
interface Payload extends Record<string, unknown> { t: string; e: string; n: string; po: ViewPortal; fn: VaFn | null; by: string }

export const VIEW_AS_TTL_S = 30 * 60;
export const PORTAL_HOME: Record<ViewPortal, string> = { account: '/account', owner: '/owner', va: '/staff', field: '/staff/field', investor: '/investor' };

export class ViewAsReadOnly extends Error {
  constructor() { super('Read only while viewing as another person. Use Exit on the red banner to go back to your own account.'); this.name = 'ViewAsReadOnly'; }
}

async function inAdminArea(): Promise<boolean> {
  try { return (await headers()).get(ADMIN_AREA_HEADER) === '1'; } catch { return false; }
}

async function rawCookie(): Promise<string | null> {
  try { return (await cookies()).get(VIEW_AS_COOKIE)?.value ?? null; } catch { return null; }
}

/** The active view-as, or null (no cookie, a bad or expired one, or the signed-in person is not that Admin now). */
export const viewAs = cache(async (): Promise<ViewAs | null> => {
  const raw = await rawCookie();
  if (!raw) return null;
  // in the Admin portal the Admin is always themselves (the Worker entry marks those requests)
  if (await inAdminArea()) return null;
  const p = await readToken<Payload>('view-as', raw);
  if (!p || !p.t || !p.by) return null;
  const a = await auth();
  const real = await a.currentUser();
  if (!real || real.id !== p.by) return null;
  const { rpc } = await import('@/lib/db/repo');
  const gate = (await rpc('admin_gate', { p_user: real.id }, { role: 'service_role', skipViewAs: true }).catch(() => null)) as unknown as { admin: boolean; two_step_required: boolean } | null;
  if (!gate?.admin) return null;
  if (gate.two_step_required && (await a.assurance()) !== 'aal2') return null;
  return { target: { id: p.t, email: p.e, name: p.n }, portal: p.po, fn: p.fn ?? null, admin: real };
});

/** The cookie value for a view-as the database has accepted (app.view_as_start). */
export async function viewAsCookieValue(admin: string, target: { user_id: string; email: string; name: string; portal: ViewPortal; function: VaFn | null }) {
  const { signToken } = await import('@/server/links');
  return signToken('view-as', { t: target.user_id, e: target.email, n: target.name, po: target.portal, fn: target.function, by: admin }, VIEW_AS_TTL_S);
}

export const viewAsCookieOptions = () => ({ httpOnly: true, secure: env().NEXT_PUBLIC_APP_URL.startsWith('https:'), sameSite: 'lax' as const, path: '/', maxAge: VIEW_AS_TTL_S });

// Database functions that only read, which a page may call for the person being viewed. Anything else made for
// that person (their id as the caller, or as p_by / p_user) is refused while viewing as them.
const READS = /^(my_|owner_portal_|site_|public_|admin_gate$|door$|sitemap_rows$|fleet$|car_page$|model_hubs?$|vehicle_classes$|handover_places$|quote_booking$|calc_cancellation$|renter_review_state$|server_file_access$|server_pdf_facts$|server_document_file$|server_owner_program_facts$|server_onboarding_options$|server_owner_invoice_id$|server_owner_agreement_facts$|server_agreement_facts$|server_booking_payment_facts$|server_owner_invoice_payment_facts$|server_extension_payment_facts$|driver_signing$|delivery_origin$|load_form_draft$|server_unsubscribe_info$|guide_read$|guide_banner$|guide_pdf_file$|owner_screen_forms$|server_owner_form_ab_facts$|sign_request_facts$)/;
export const isViewAsRead = (fn: string) => READS.test(fn);

/** For the database layer: is this call made for the person being viewed, and is it a write? */
export function refusedForViewAs(v: ViewAs, fn: string, args: Record<string, unknown>, userId: string | undefined): boolean {
  const forTarget = userId === v.target.id || args.p_by === v.target.id || args.p_user === v.target.id;
  return forTarget && !isViewAsRead(fn);
}

/** The person's access token for this render (made once). */
export const viewAsToken = cache(async (): Promise<string | null> => {
  const v = await viewAs();
  return v ? viewAsAccessToken(v) : null;
});

/** An access token for the person being viewed (5 minutes, server side only): their reads go through row-level
 *  security exactly as theirs would. Signed with the project's JWT secret (SUPABASE_JWT_SECRET) on Supabase, with
 *  LOCAL_AUTH_SECRET on the local stack. */
export async function viewAsAccessToken(v: ViewAs): Promise<string> {
  const e = env();
  const secret = e.DATA_BACKEND === 'local' ? e.LOCAL_AUTH_SECRET : e.SUPABASE_JWT_SECRET;
  if (!secret) throw new Error('Viewing this portal as another person needs SUPABASE_JWT_SECRET (the deploy sets it).');
  const { SignJWT } = await import('jose');
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ email: v.target.email, role: 'authenticated', aal: 'aal1', is_anonymous: false, view_as_by: v.admin.id })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' }).setSubject(v.target.id).setAudience('authenticated')
    .setIssuer(e.DATA_BACKEND === 'local' ? 'local' : `${(e.NEXT_PUBLIC_SUPABASE_URL ?? '').replace(/\/$/, '')}/auth/v1`)
    .setIssuedAt(now).setExpirationTime(now + 300).sign(new TextEncoder().encode(secret));
}
