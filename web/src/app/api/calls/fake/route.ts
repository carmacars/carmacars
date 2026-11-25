import { NextResponse } from 'next/server';
import { mediaConfig } from '@/server/calls';

// r50 (5010): the fake media's relay (CALLS_PROVIDER=fake: local development and CI only; never in production, where
// mediaConfig() is never fake). No audio or video: who is in each room and the data messages, kept in this process.
export const dynamic = 'force-dynamic';
interface Wire { n: number; k: string; from: string; name: string; role: string; state?: unknown; msg?: unknown; at: number }
const g = globalThis as unknown as { __ccFakeCalls?: Map<string, { n: number; log: Wire[] }> };
const rooms = (g.__ccFakeCalls ??= new Map());
const off = () => mediaConfig().provider !== 'fake';
const H = { 'cache-control': 'no-store' };

export async function POST(req: Request) {
  if (off()) return new NextResponse('not found', { status: 404 });
  const b = (await req.json().catch(() => null)) as { room?: string; wire?: Omit<Wire, 'n' | 'at'> } | null;
  if (!b?.room || !/^[a-z0-9-]{6,80}$/.test(b.room) || !b.wire || !/^(u|g)-[0-9a-f-]{36}$/.test(String(b.wire.from))) return NextResponse.json({ error: 'bad' }, { status: 400 });
  const r = rooms.get(b.room) ?? { n: 0, log: [] };
  r.n += 1;
  r.log.push({ ...b.wire, n: r.n, at: Date.now() });
  if (r.log.length > 500) r.log.splice(0, r.log.length - 500);
  rooms.set(b.room, r);
  return NextResponse.json({ n: r.n }, { headers: H });
}

export async function GET(req: Request) {
  if (off()) return new NextResponse('not found', { status: 404 });
  const u = new URL(req.url);
  const room = u.searchParams.get('room') ?? '';
  const since = Number(u.searchParams.get('since') ?? 0) || 0;
  const r = rooms.get(room);
  return NextResponse.json({ n: r?.n ?? 0, wires: (r?.log ?? []).filter((w: Wire) => w.n > since) }, { headers: H });
}
