import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';

// RFC 8058 one-click unsubscribe: mail apps POST "List-Unsubscribe=One-Click" to the List-Unsubscribe URL
// (send-outbox sets it to this route with the email's token). A GET (a person, or an old client) goes to the
// page, which asks before acting.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function POST(req: Request) {
  const token = new URL(req.url).searchParams.get('token') ?? '';
  if (!UUID.test(token)) return NextResponse.json({ ok: false }, { status: 400 });
  const ok = (await rpc('server_unsubscribe', { p_token: token }, { role: 'service_role' })) as unknown as boolean;
  return NextResponse.json({ ok }, { status: ok ? 200 : 404 });
}

export function GET(req: Request) {
  const u = new URL(req.url);
  return NextResponse.redirect(new URL(`/unsubscribe${u.search}`, u), 303);
}
