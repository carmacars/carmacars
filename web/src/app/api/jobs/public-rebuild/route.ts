import { NextResponse } from 'next/server';
import { revalidatePath } from 'next/cache';
import { workerToken } from '@/server/listing-worker';
import { rpc } from '@/lib/db/repo';
import { signatureOf } from '@/lib/edge/fleet-sig';

// The public pages rebuilt after the fleet changed in the database alone (src/lib/edge/fleet-sig.ts): the fleet page,
// home, the model pages, the car pages, the landing pages and the sitemaps (every page under the root layout; on
// Cloudflare this also retires the Worker entry's edge copies, src/lib/edge/tag-cache-gen.ts). Called with the
// listing worker's bearer token by the Worker's cron tick when the fleet's signature changed, and every few seconds by
// scripts/serve.mjs locally with {"check": true}: then the route reads the signature itself and rebuilds only when it
// differs from the last one this server saw.
export const dynamic = 'force-dynamic';

let last: number | null = null;
let confirm = false;

export async function POST(req: Request) {
  const want = await workerToken();
  const got = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  let d = want.length ^ got.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  if (d !== 0) return new NextResponse('Forbidden', { status: 403 });
  try {
    const body = (await req.json().catch(() => ({}))) as { check?: boolean };
    const sig = signatureOf(((await rpc('fleet', { p_filters: {} })) ?? []) as unknown as Array<{ slug?: string; model_hub_path?: string }>);
    // a page regenerated while the change was being written can keep the old list: after a change, the next check
    // rebuilds once more (the confirm), so no stale link survives
    if (body.check && last !== null && sig === last && !confirm) return NextResponse.json({ ok: true, rebuilt: false, sig });
    revalidatePath('/', 'layout');
    revalidatePath('/sitemap.xml');
    confirm = body.check ? (sig !== last) : false;
    last = sig;
    return NextResponse.json({ ok: true, rebuilt: true, sig });
  } catch (e) {
    return NextResponse.json({ ok: false, error: e instanceof Error ? e.message.slice(0, 300) : 'failed' }, { status: 500 });
  }
}
