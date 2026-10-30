import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { currentUser, realUser } from '@/server/portal/data';
import { env } from '@/lib/env';

// A follow from the Rewards page (migration 0212): the points are given on this click (a follow cannot be checked), once
// per platform, then the browser goes on to the page. While an Admin views as a renter, no points: just the page.
export const dynamic = 'force-dynamic';
export async function GET(_req: Request, { params }: { params: Promise<{ platform: string }> }) {
  const { platform } = await params;
  const back = new URL('/account/rewards', env().NEXT_PUBLIC_APP_URL);
  if (!['instagram', 'tiktok', 'facebook'].includes(platform)) return NextResponse.redirect(back, 302);
  const [user, real] = await Promise.all([currentUser(), realUser()]);
  try {
    const opts = user && real && user.id === real.id ? { role: 'authenticated' as const, userId: user.id } : { role: 'service_role' as const };
    const r = (await rpc('rewards_mine_social', { p_platform: platform }, opts)) as unknown as { url: string };
    return NextResponse.redirect(r.url, 302);
  } catch {
    return NextResponse.redirect(back, 302);
  }
}
