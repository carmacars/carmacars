import { realUser } from '@/server/portal/data';
import { fileResponse } from '@/server/files';
import { loadBundle, renderBlindSpot } from '@/server/agreements/bundle';

// 0544: the Blind Spot agreement of a booking as it is filled now, with what staff typed over it (Type into the
// agreement): the unsigned preview to check before the corrected version is made. Staff only (the facts refuse anyone
// else); nothing is stored.
export const dynamic = 'force-dynamic';
export async function GET(_req: Request, { params }: { params: Promise<{ booking: string }> }) {
  const { booking } = await params;
  if (!/^[0-9a-f-]{36}$/.test(booking)) return new Response('Not found', { status: 404 });
  const user = await realUser();
  if (!user) return new Response('Not found', { status: 404 });
  try {
    const b = await loadBundle(booking, user.id);
    const bytes = await renderBlindSpot(b, { title: `Blind Spot rental agreement ${b.f.booking.booking_number} (preview)` });
    if (!bytes) return new Response('No Blind Spot form is set up (Admin > Settings > Forms)', { status: 404 });
    return fileResponse({ bytes, fileName: `blindspot-${b.f.booking.booking_number}-preview.pdf`, contentType: 'application/pdf' });
  } catch {
    return new Response('Not found', { status: 404 });
  }
}
