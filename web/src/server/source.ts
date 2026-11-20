import 'server-only';
import { cookies } from 'next/headers';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { parseSource, SRC_COOKIE, type SourceCookie } from '@/lib/track/source';

// Where the person who sent this form came from (release 48, migration 3230): the first-touch cookie of
// src/lib/track/source.ts, read when a lead or a request to book is stored. Never a reason for a form to fail.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export async function readSource(): Promise<{ src: SourceCookie; vid: string | null } | null> {
  try {
    const jar = await cookies();
    const src = parseSource(jar.get(SRC_COOKIE)?.value);
    if (!src) return null;
    const vid = jar.get('cc_vid')?.value ?? '';
    return { src, vid: UUID.test(vid) ? vid : null };
  } catch { return null; }
}

/** The campaign tags and the referring page for public.submit_lead's own columns. */
export async function leadSourceFields(): Promise<{ utm?: Record<string, string>; referrer?: string }> {
  const s = await readSource();
  if (!s) return {};
  return { ...(s.src.f.utm ? { utm: s.src.f.utm } : {}), ...(s.src.f.ref ? { referrer: s.src.f.ref.split('?')[0] } : {}) };
}

/** Stores the source with a lead (its id), a request to book (its number) or a chauffeur request (its reference). */
export async function storeSource(to: { lead?: string | null; bookingNumber?: string | null; chauffeurRef?: string | null }): Promise<void> {
  try {
    if (!to.lead && !to.bookingNumber && !to.chauffeurRef) return;
    const s = await readSource();
    if (!s) return;
    await rpc('server_contact_source_set', { p_lead: to.lead ?? undefined, p_booking_number: to.bookingNumber ?? undefined, p_chauffeur_ref: to.chauffeurRef ?? undefined,
      p: { vid: s.vid, first: s.src.f, last: s.src.l ?? null } as unknown as Json }, { role: 'service_role' });
  } catch { /* the lead or the request is already stored */ }
}
