import { NextResponse } from 'next/server';
import { currentUser } from '@/server/portal/data';
import { door } from '@/server/door';
import { siteUrl } from '@/lib/site';

// 1068: Join the call from the townhall page: counts the staff member as there (from 15 minutes before), then opens the
// call. Before that window it goes back to the townhall page; without an outside link (R50 hotfix 2, 5072) it opens the
// call in the site (the staff page sends an Admin to the Admin's).
export const dynamic = 'force-dynamic';
export async function GET() {
  const user = await currentUser();
  if (!user) return NextResponse.redirect(`${siteUrl()}/sign-in?next=/staff/townhall`);
  const r = await door<{ ok: boolean; call_url: string | null }>(user.id, 'ops_do', 'townhall_attend', { method: 'join' }).catch(() => null);
  const url = r?.call_url ?? (await door<{ call_url: string | null }>(user.id, 'ops_read', 'townhall', {}).catch(() => null))?.call_url ?? null;
  if (url && /^https:\/\//.test(url)) return NextResponse.redirect(url, { headers: { 'cache-control': 'private, no-store' } });
  return NextResponse.redirect(`${siteUrl()}${r?.ok && !url ? '/staff/townhall/live' : '/staff/townhall'}`);
}
