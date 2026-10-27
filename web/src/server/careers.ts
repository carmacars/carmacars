import 'server-only';
import { cache } from 'react';
import { rpc } from '@/lib/db/repo';
import type { RoleCard, RolePublic } from '@/features/careers/model';

// The careers pages' reads (migration 0173). The open roles and a role's page are public reads (anon, kept per Worker like the
// footer links); the booking page and the referral's contact details are read as the server with the candidate's token.
const SR = { role: 'service_role' as const };
const TOKEN = /^[0-9a-f]{64}$/;

export const openRoles = cache(async (): Promise<RoleCard[]> => {
  try { return ((await rpc('hiring_roles_public', {})) ?? []) as unknown as RoleCard[]; } catch { return []; }
});
export const rolePage = cache(async (slug: string): Promise<RolePublic | null> => {
  if (!/^[a-z0-9-]{2,60}$/.test(slug)) return null;
  return ((await rpc('hiring_role_public', { p_slug: slug }).catch(() => null)) ?? null) as unknown as RolePublic | null;
});

export interface BookingView {
  ok: true; first_name: string; role_title: string; remote: boolean; status: string; can_book: boolean; phone_last: string;
  booked: { slot_id: string; starts_at: string; ends_at: string; mode: 'phone' | 'video'; meet_url: string | null } | null;
  slots: Array<{ id: string; starts_at: string; ends_at: string; mode: 'phone' | 'video'; day: string }>;
}
export async function bookingView(token: string): Promise<BookingView | null> {
  if (!TOKEN.test(token)) return null;
  const r = (await rpc('server_hiring_booking', { p_token: token }, SR).catch(() => null)) as unknown as BookingView | { ok: false } | null;
  return r && r.ok ? r : null;
}
export async function referralPrefill(token: string | undefined, slug: string): Promise<{ full_name: string; email: string; phone: string; from_role: string } | null> {
  if (!token || !TOKEN.test(token)) return null;
  const r = (await rpc('server_hiring_prefill', { p_token: token, p_slug: slug }, SR).catch(() => null)) as unknown as { ok: true; full_name: string; email: string; phone: string; from_role: string } | null;
  return r && r.ok ? r : null;
}
