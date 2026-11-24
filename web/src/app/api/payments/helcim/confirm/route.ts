import { foreignOrigin } from '@/lib/security/same-origin';
import { helcimOnly } from '@/integrations/payments';

// r50: what the HelcimPay.js modal reported in the browser (lib/card-js.ts), for the payment of its checkout session.
// Nothing is trusted from the browser: the answer counts only when its hash matches the session's secret token (kept on
// our server), and the transaction is then read again from Helcim (amount, type, approved) before the payment is marked
// paid or held (helcim.ts confirmCheckout). The card form then calls its own finish step as with Stripe (settle, record,
// capture), and the webhook would do the same if the browser never came back. renew: a declined card used the session up,
// so a new one is made for the next try. Idempotent: a second call for a payment already confirmed returns it unchanged.
export const dynamic = 'force-dynamic';

export async function POST(req: Request): Promise<Response> {
  if (foreignOrigin(req.headers.get('origin'), req.headers.get('host'), req.headers.get('sec-fetch-site'))) return Response.json({ ok: false, error: 'Not allowed' }, { status: 403 });
  const h = await helcimOnly();
  if (!h) return Response.json({ ok: false, error: 'Helcim is not the card processor' }, { status: 409 });
  const raw = await req.text();
  if (raw.length > 20_000) return Response.json({ ok: false, error: 'Too large' }, { status: 413 });
  let body: { checkoutToken?: unknown; message?: unknown; renew?: unknown };
  try { body = JSON.parse(raw) as typeof body; } catch { return Response.json({ ok: false, error: 'Not JSON' }, { status: 400 }); }
  const token = typeof body.checkoutToken === 'string' && /^[A-Za-z0-9_-]{4,200}$/.test(body.checkoutToken) ? body.checkoutToken : '';
  const id = token ? await h.idForCheckout(token) : null;
  if (!id) return Response.json({ ok: false, error: 'This card window expired: reload the page' }, { status: 404 });
  try {
    if (body.renew === true) {
      const i = await h.renewCheckout(id);
      return Response.json({ ok: true, id: i.id, status: i.status, checkoutToken: i.clientSecret });
    }
    const i = await h.confirmCheckout(id, body.message);
    return Response.json({ ok: i.status === 'requires_capture' || i.status === 'succeeded', id: i.id, status: i.status, error: i.lastError ?? undefined });
  } catch (e) {
    return Response.json({ ok: false, error: e instanceof Error ? e.message.slice(0, 200) : 'The card could not be confirmed' }, { status: 400 });
  }
}
