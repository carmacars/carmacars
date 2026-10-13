import { NextResponse } from 'next/server';
import { env } from '@/lib/env';
import { supabaseServer } from '@/lib/supabase/server';

// Supabase Auth email links land here with a one-time code (password reset, email confirmation:
// PKCE) or a token hash (staff invitations: the invite email template links here with
// token_hash and type=invite, because an invite is created on the server without a PKCE verifier).
// Either becomes a session cookie; then the person continues to `next`.
export const dynamic = 'force-dynamic';
export async function GET(req: Request) {
  const u = new URL(req.url);
  const next = /^\/(?!\/)[\w\-/]*$/.test(u.searchParams.get('next') ?? '') ? u.searchParams.get('next')! : '/account';
  const code = u.searchParams.get('code');
  const tokenHash = u.searchParams.get('token_hash');
  const type = u.searchParams.get('type');
  if (env().DATA_BACKEND === 'supabase' && code) {
    const s = await supabaseServer();
    const { error } = await s.auth.exchangeCodeForSession(code);
    if (!error) return NextResponse.redirect(new URL(next, u.origin));
  } else if (env().DATA_BACKEND === 'supabase' && tokenHash && (type === 'invite' || type === 'recovery' || type === 'email' || type === 'signup' || type === 'magiclink' || type === 'email_change')) {
    const s = await supabaseServer();
    const { error } = await s.auth.verifyOtp({ token_hash: tokenHash, type });
    if (!error) return NextResponse.redirect(new URL(next, u.origin));
  }
  return NextResponse.redirect(new URL('/sign-in?error=link', u.origin));
}
