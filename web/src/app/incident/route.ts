import { localRedirect } from '@/lib/http/local-redirect';
import { incidentRedirect } from '@/features/incident-cards/digital';

// The printed incident card's QR code (1150): one fixed address for every car. It opens the renter's digital incident card
// in the renter portal, which asks to sign in first and then shows their booking in progress. Nothing is read here.
export const dynamic = 'force-dynamic';

export function GET(req: Request) {
  const u = new URL(req.url);
  return localRedirect(incidentRedirect(u.searchParams.get('b')), 302, { 'cache-control': 'no-store' });
}
