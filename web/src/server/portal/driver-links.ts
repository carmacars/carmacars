import 'server-only';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import { signTokenUntil } from '@/server/links';

// An additional driver's signing link (migration 0040): it names the signer row and a version and is valid until the
// expiry the database keeps, so the page can show the same link again; a new link raises the version.
const SR = { role: 'service_role' as const };
export interface DriverLink { signer_id: string; name: string; email: string | null; booking_driver_id: string | null; signed_at: string | null; version: number; expires_at: string | null; expired: boolean; sent_at: string | null; sent_count: number }

export async function driverLinkUrl(signerId: string, version: number, expiresAt: string): Promise<string> {
  const base = env().NEXT_PUBLIC_APP_URL.replace(/\/$/, '');
  return `${base}/sign/driver/${await signTokenUntil('driver-sign', { s: signerId, v: version }, new Date(expiresAt))}`;
}

export async function bookingDriverLinks(bookingId: string, by: string): Promise<Array<DriverLink & { url: string | null }>> {
  const rows = (await rpc('server_booking_driver_links', { p_booking: bookingId, p_by: by }, SR).catch(() => [])) as unknown as DriverLink[];
  return Promise.all((rows ?? []).map(async (r) => ({ ...r, url: !r.signed_at && !r.expired && r.expires_at ? await driverLinkUrl(r.signer_id, r.version, r.expires_at) : null })));
}

/** When the renter's agreement is opened: each additional driver with an email address gets their link once. */
export async function sendFirstDriverLinks(bookingId: string, by: string): Promise<void> {
  for (const r of await bookingDriverLinks(bookingId, by)) {
    if (r.signed_at || r.sent_count > 0 || !r.email || !r.url) continue;
    await rpc('server_driver_link_send', { p_signer: r.signer_id, p_by: by, p_version: r.version, p_url: r.url }, SR).catch(() => undefined);
  }
}
