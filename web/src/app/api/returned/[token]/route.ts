import { NextResponse } from 'next/server';
import { foreignOrigin } from '@/lib/security/same-origin';
import { rpc } from '@/lib/db/repo';
import { currentUser } from '@/server/portal/data';
import { claimPayload, UUID, type ClaimInput } from '@/features/returns/claim';

// The renter's "I've returned the car" report (migration 0532): by the booking's link, signed in or not. The database
// pauses every overdue notice of the booking at once, marks it returned, waiting for confirmation, keeps the readings
// as renter-provided and opens Fleet's To do. Sending it twice changes nothing.
export const dynamic = 'force-dynamic';


export async function POST(req: Request, { params }: { params: Promise<{ token: string }> }) {
  const origin = req.headers.get('origin');
  // r44: the shared rule: "null" from an in-app browser (the text message's link) is this site when same-origin
  if (foreignOrigin(origin, req.headers.get('host'), req.headers.get('sec-fetch-site'))) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const { token } = await params;
  if (!UUID.test(token)) return NextResponse.json({ ok: false, message: 'This link is not valid.' }, { status: 404 });
  const body = (await req.json().catch(() => null)) as ClaimInput | null;
  const v = claimPayload(body ?? {});
  if (!v.ok) return NextResponse.json({ ok: false, message: v.message }, { status: 400 });
  // The report is always taken (hotfix Nov 12). With the dashboard photo, the odometer, the fuel and the selfie the database
  // completes the trip at once (0545, 0910); without them staff confirm the return.
  const user = await currentUser().catch(() => null);
  try {
    const r = (await rpc('server_return_claim_submit', { p_token: token, p: v.payload as never, p_user: user?.id ?? null } as never,
      { role: 'service_role', skipViewAs: true })) as unknown as { status: string };
    return NextResponse.json({ ok: true, status: r.status });
  } catch (e) {
    const message = e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '') : 'The report could not be sent.';
    return NextResponse.json({ ok: false, message }, { status: 422 });
  }
}
