import { rpc } from '@/lib/db/repo';

// 0212: whether email is at its daily or monthly limit (or held by the provider's), for the sign-in page to open on the
// phone option while it is. {"capped": boolean, "phone_signin": boolean}; nothing personal. Cached a minute.
export const dynamic = 'force-dynamic';

export async function GET() {
  const headers = { 'cache-control': 'public, max-age=60', 'content-type': 'application/json' };
  try {
    const r = (await rpc('server_email_capped', {} as never, { role: 'service_role' })) as unknown as { capped: boolean; phone_signin: boolean } | null;
    return new Response(JSON.stringify({ capped: r?.capped === true, phone_signin: r?.phone_signin === true }), { headers });
  } catch {
    return new Response(JSON.stringify({ capped: false, phone_signin: false }), { headers });
  }
}
