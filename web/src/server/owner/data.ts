import 'server-only';
import { notFound, redirect } from 'next/navigation';
import type { SessionUser } from '@/lib/auth';
import { DbError, rpc } from '@/lib/db/repo';
import { currentUser } from '@/server/portal/data';
import type { OwnerBooking, OwnerDoc, OwnerForm, OwnerHome, OwnerInvoice, OwnerStatement } from '@/features/owner/types';

// Reads for the owner portal (migration 0029). The portal functions take the signed-in user's id and
// answer only for an active owner account (app.portal_owner_id); the service role calls them because
// the app schema is not exposed. Nothing here trusts an id from the browser without that check.
const SR = { role: 'service_role' as const };

export async function requireOwnerUser(next = '/owner'): Promise<SessionUser> {
  const u = await currentUser();
  if (!u) redirect(`/sign-in?next=${encodeURIComponent(next)}`);
  return u;
}

/** The owner's home data, or null when the signed-in account is not an owner. */
export async function ownerHome(u: SessionUser): Promise<OwnerHome | null> {
  try {
    return (await rpc('owner_portal_home', { p_by: u.id }, SR)) as unknown as OwnerHome;
  } catch (e) {
    if (e instanceof DbError && /Not an owner account/.test(e.message)) return null;
    throw e;
  }
}

export async function requireOwner(next = '/owner'): Promise<{ user: SessionUser; home: OwnerHome }> {
  const user = await requireOwnerUser(next);
  const home = await ownerHome(user);
  if (!home) redirect('/owner/not-an-owner');
  return { user, home };
}

export async function ownerInvoice(u: SessionUser, number: string): Promise<OwnerInvoice> {
  if (!/^[A-Z]{2,4}-\d{1,10}$/i.test(number)) notFound();
  const i = (await rpc('owner_portal_invoice', { p_by: u.id, p_number: number }, SR)) as unknown as OwnerInvoice | null;
  if (!i) notFound();
  return i;
}

export async function ownerStatement(u: SessionUser, id: string): Promise<OwnerStatement> {
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const s = (await rpc('owner_portal_statement', { p_by: u.id, p_statement: id }, SR)) as unknown as OwnerStatement | null;
  if (!s) notFound();
  return s;
}

export async function ownerBookings(u: SessionUser, from?: string, to?: string): Promise<OwnerBooking[]> {
  return ((await rpc('owner_portal_bookings', { p_by: u.id, p_from: from, p_to: to }, SR)) ?? []) as unknown as OwnerBooking[];
}
export async function ownerDocuments(u: SessionUser): Promise<OwnerDoc[]> {
  return ((await rpc('owner_portal_documents', { p_by: u.id }, SR)) ?? []) as unknown as OwnerDoc[];
}
export async function ownerForms(u: SessionUser): Promise<OwnerForm[]> {
  return ((await rpc('owner_portal_forms', { p_by: u.id }, SR)) ?? []) as unknown as OwnerForm[];
}
