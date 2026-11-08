import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { currentUser } from '@/server/portal/data';
import { claimPayload, UUID, type ClaimInput } from '@/features/returns/claim';
import { serverReadingProblem } from '@/features/handover/reading';

// The renter's "I've returned the car" report (migration 0532): by the booking's link, signed in or not. The database
// pauses every overdue notice of the booking at once, marks it returned, waiting for confirmation, keeps the readings
// as renter-provided and opens Fleet's To do. Sending it twice changes nothing.
export const dynamic = 'force-dynamic';

export async function POST(req: Request, { params }: { params: Promise<{ token: string }> }) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false, message: 'Not permitted.' }, { status: 403 });
  const { token } = await params;
  if (!UUID.test(token)) return NextResponse.json({ ok: false, message: 'This link is not valid.' }, { status: 404 });
  const body = (await req.json().catch(() => null)) as ClaimInput | null;
  const v = claimPayload(body ?? {});
  if (!v.ok) return NextResponse.json({ ok: false, message: v.message }, { status: 400 });
  // 0910: the dashboard photo, the odometer, the fuel in eighths and the live selfie are required at every check-in
  const problem = serverReadingProblem({ odometer_km: String(v.payload.odometer_km ?? ''), fuel_pct: String(v.payload.fuel_pct ?? ''),
    photos: (v.payload.photos ?? []) as Array<{ angle?: string | null }> });
  if (problem) return NextResponse.json({ ok: false, message: problem }, { status: 400 });
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
