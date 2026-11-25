import { NextResponse } from 'next/server';
import { env } from '@/lib/env';
import { recordEvent } from '@/server/calls';
import { verifyWebhook, webhookEvent } from '@/features/calls/token';

// r50 (5010): the media server's webhook (LiveKit, infra/vps/livekit): who joined or left which room. Signed with our API
// key and secret over the body's hash; anything else is refused. Attendance follows from it in the database.
export const dynamic = 'force-dynamic';
export async function POST(req: Request) {
  const e = env();
  if (!e.LIVEKIT_API_KEY || !e.LIVEKIT_API_SECRET) return new NextResponse('not configured', { status: 404 });
  const body = await req.text();
  if (body.length > 64_000 || !(await verifyWebhook(e.LIVEKIT_API_KEY, e.LIVEKIT_API_SECRET, body, req.headers.get('authorization')))) return new NextResponse('unauthorized', { status: 401 });
  let j: unknown = null;
  try { j = JSON.parse(body); } catch { return new NextResponse('bad body', { status: 400 }); }
  const ev = webhookEvent(j);
  if (ev) await recordEvent(ev.room, ev.identity, ev.event, ev.at).catch(() => null);
  return NextResponse.json({ ok: true });
}
