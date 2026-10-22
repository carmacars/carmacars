import { handleSmsHook } from '@/server/auth-sms';

// Supabase Auth's Send SMS hook (migration 0091): every sign-in code and phone verification code. The signature is
// checked on the raw body before anything is read (src/features/auth/sms-hook.ts); the text goes out through the Quo
// line from the CarmaCars number. Supabase waits about 5 seconds: the work is two database calls and one text.
export const dynamic = 'force-dynamic';

export async function POST(req: Request): Promise<Response> {
  const raw = await req.text();
  if (raw.length > 64_000) return Response.json({ error: { http_code: 413, message: 'too large' } }, { status: 413 });
  try {
    const r = await handleSmsHook(raw, (n) => req.headers.get(n));
    return Response.json(r.body, { status: r.status });
  } catch {
    return Response.json({ error: { http_code: 500, message: 'The code could not be texted. Try again in a minute.' } }, { status: 500 });
  }
}
