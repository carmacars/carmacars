import { NextResponse } from 'next/server';
import { env } from '@/lib/env';
import { supabaseServer } from '@/lib/supabase/server';
import { safeNext } from '@/server/portals';

// Supabase Auth email links land here with a token hash (every template: scripts/deploy/auth-templates.mjs) or a
// one-time code (PKCE, a link asked for on this same browser). Either becomes a session cookie; then the person
// continues to `next` (choosing a password: /update-password, which then sends them to their portal). A link that
// has expired or was used already goes to /link-expired, which sends a new one in one step.
export const dynamic = 'force-dynamic';
const TYPES = new Set(['invite', 'recovery', 'email', 'signup', 'magiclink', 'email_change']);
export async function GET(req: Request) {
  const u = new URL(req.url);
  const next = safeNext(u.searchParams.get('next')) ?? '/account';
  const code = u.searchParams.get('code');
  const tokenHash = u.searchParams.get('token_hash');
  const type = u.searchParams.get('type') ?? '';
  if (env().DATA_BACKEND === 'supabase' && tokenHash && TYPES.has(type)) {
    const s = await supabaseServer();
    const { error } = await s.auth.verifyOtp({ token_hash: tokenHash, type: type as 'invite' });
    if (!error) return NextResponse.redirect(new URL(next, u.origin));
  } else if (env().DATA_BACKEND === 'supabase' && code) {
    const s = await supabaseServer();
    const { error } = await s.auth.exchangeCodeForSession(code);
    if (!error) return NextResponse.redirect(new URL(next, u.origin));
  }
  // Supabase sends people here with ?error=...&error_code=otp_expired when its own page refused the link
  const kind = type === 'signup' || type === 'email' ? 'confirm' : type === 'invite' ? 'invite' : 'password';
  return NextResponse.redirect(new URL(`/link-expired?kind=${kind}`, u.origin));
}
