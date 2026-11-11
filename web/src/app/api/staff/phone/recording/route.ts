import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { rpc } from '@/lib/db/repo';

// 1880: "Play recording" on a call made from the site's Call button. The database decides who may hear it (the same people
// as the calls and texts: Admins, customer service and Sales, app.server_phone_recording); the audio is in private storage
// and this answers with a short-lived signed link to it.
export const dynamic = 'force-dynamic';
const H = { 'cache-control': 'no-store' };

export async function GET(req: Request) {
  const user = await currentUser();
  if (!user) return NextResponse.json({ error: 'Sign in first' }, { status: 401, headers: H });
  const id = new URL(req.url).searchParams.get('id') ?? '';
  if (!/^[0-9a-f-]{36}$/i.test(id)) return NextResponse.json({ error: 'Unknown call' }, { status: 400, headers: H });
  let key: string;
  try {
    key = (await rpc('server_phone_recording', { p_user: user.id, p_activity: id }, { role: 'service_role' })) as unknown as string;
  } catch (e) {
    const m = e instanceof Error ? e.message.replace(/^.*?ERROR:\s*/, '').slice(0, 200) : 'Not permitted';
    return NextResponse.json({ error: m }, { status: /No recording/.test(m) ? 404 : 403, headers: H });
  }
  const { storage } = await import('@/integrations/storage');
  const url = await (await storage()).signedDownloadUrl('documents', key, 300);
  return NextResponse.redirect(url, { status: 302, headers: H });
}
