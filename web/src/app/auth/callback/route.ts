import { NextResponse } from 'next/server';
import { env } from '@/lib/env';
import { supabaseServer } from '@/lib/supabase/server';

// Supabase Auth email links (password reset, email confirmation) land here with a one-time code,
// which becomes a session cookie; then the person continues to `next`.
export const dynamic = 'force-dynamic';
export async function GET(req: Request) {
  const u = new URL(req.url);
  const next = /^\/(?!\/)[\w\-/]*$/.test(u.searchParams.get('next') ?? '') ? u.searchParams.get('next')! : '/account';
  const code = u.searchParams.get('code');
  if (env().DATA_BACKEND === 'supabase' && code) {
    const s = await supabaseServer();
    const { error } = await s.auth.exchangeCodeForSession(code);
    if (!error) return NextResponse.redirect(new URL(next, u.origin));
  }
  return NextResponse.redirect(new URL('/sign-in?error=link', u.origin));
}
