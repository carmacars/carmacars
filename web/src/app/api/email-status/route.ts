import { rpc } from '@/lib/db/repo';

// 0212: whether email is at its daily or monthly limit (or held by the provider's), for the sign-in page to open on the
// phone option while it is (and texts work). {"capped": boolean, "phone_signin": boolean, "sms_ok": boolean}; nothing personal. Cached a minute.
export const dynamic = 'force-dynamic';

export async function GET() {
  const headers = { 'cache-control': 'public, max-age=60', 'content-type': 'application/json' };
  try {
    const r = (await rpc('server_email_capped', {} as never, { role: 'service_role' })) as unknown as { capped: boolean; phone_signin: boolean; sms_ok?: boolean } | null;
    // 3410: sms_ok false while the last 3 sign-in texts failed: the page then keeps the password form first
    return new Response(JSON.stringify({ capped: r?.capped === true, phone_signin: r?.phone_signin === true, sms_ok: r?.sms_ok !== false }), { headers });
  } catch {
    return new Response(JSON.stringify({ capped: false, phone_signin: false, sms_ok: true }), { headers });
  }
}
