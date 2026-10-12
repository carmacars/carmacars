import { NextResponse } from 'next/server';
import { BROWSER_FUNCTIONS, DbError, rpc, type FnName } from '@/lib/db/repo';
import { env } from '@/lib/env';

// LOCAL STACK ONLY. The browser's public reads (calendar, quote, search, cookie choice) go to the
// Supabase API in production. Locally there is no PostgREST, so this route calls the same function
// as the anonymous role. Anything not on the list of anonymous functions is refused.
export const dynamic = 'force-dynamic';

export async function POST(req: Request, ctx: { params: Promise<{ fn: string }> }) {
  if (env().DATA_BACKEND !== 'local') return NextResponse.json({ error: 'Not found' }, { status: 404 });
  const { fn } = await ctx.params;
  if (!BROWSER_FUNCTIONS.has(fn as FnName)) return NextResponse.json({ error: 'Not found' }, { status: 404 });
  let args: Record<string, unknown> = {};
  try { args = (await req.json()) as Record<string, unknown>; } catch { /* no body */ }
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const data = await rpc(fn as FnName, args as any, { role: 'anon' });
    return NextResponse.json({ data });
  } catch (e) {
    const err = e as DbError;
    return NextResponse.json({ error: err.message, code: err.code }, { status: err.code === '42501' ? 403 : 400 });
  }
}
