import { currentUser } from '@/server/portal/data';
import { door } from '@/server/door';

// The person leaves a booking request without answering it (the page closes or they go elsewhere): their claim ends now
// instead of running out (migration 0177). Sent with keepalive from RequestClaim.tsx; the database checks it is theirs.
export const dynamic = 'force-dynamic';
export async function POST(req: Request) {
  const user = await currentUser();
  if (!user) return new Response(null, { status: 204 });
  let body: { booking?: unknown; va?: unknown } = {};
  try { body = (await req.json()) as typeof body; } catch { return new Response(null, { status: 204 }); }
  const booking = typeof body.booking === 'string' && /^[0-9a-f-]{36}$/i.test(body.booking) ? body.booking : null;
  if (!booking) return new Response(null, { status: 204 });
  const va = typeof body.va === 'string' && ['cs', 'sales', 'fleet', 'finance'].includes(body.va) ? body.va : null;
  await door(user.id, 'ops_do', 'request_release', { booking, ...(va ? { _va: va } : {}) }).catch(() => undefined);
  return new Response(null, { status: 204 });
}
