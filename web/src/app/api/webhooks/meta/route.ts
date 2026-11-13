import { NextResponse, after } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { env } from '@/lib/env';
import { incomingMessages, sendMetaReply, verifyMetaSignature } from '@/integrations/meta-messaging';
import { autoReply } from '@/server/auto-reply';
import { sameSecret } from '@/lib/security/same-origin';

// AI auto-replies on Messenger, Instagram and WhatsApp (release 36, migration 2110): Meta's webhook. GET is Meta's check
// when the webhook is added (the verify token of Program settings auto_reply_meta_verify_token); POST is a delivery,
// trusted only with a valid signature (the Worker's META_APP_SECRET; unset: nothing is read). Meta wants a 200 at once: the
// answers are worked out after it (the FAQ, the free Workers AI allowance, the To do for staff when unsure).
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };
interface Cfg { verify_token: string; graph_version: string; page_token: string | null; whatsapp_phone_id: string | null; on: Record<'messenger' | 'instagram' | 'whatsapp', boolean> }

export async function GET(req: Request) {
  const u = new URL(req.url);
  if (u.searchParams.get('hub.mode') !== 'subscribe') return new NextResponse('Not found', { status: 404 });
  const cfg = (await rpc('server_meta_messaging', {}, SR).catch(() => null)) as unknown as Cfg | null;
  const token = u.searchParams.get('hub.verify_token') ?? '';
  if (!cfg?.verify_token || !sameSecret(token, cfg.verify_token)) return new NextResponse('Forbidden', { status: 403 });
  return new NextResponse((u.searchParams.get('hub.challenge') ?? '').replace(/[^\w.-]/g, '').slice(0, 200), { headers: { 'content-type': 'text/plain' } });
}

export async function POST(req: Request) {
  const raw = await req.text();
  if (raw.length > 512_000) return NextResponse.json({ error: 'too large' }, { status: 413 });
  const secret = env().META_APP_SECRET ?? '';
  if (!(await verifyMetaSignature(raw, req.headers.get('x-hub-signature-256'), secret))) return NextResponse.json({ error: 'invalid signature' }, { status: 401 });
  let body: unknown;
  try { body = JSON.parse(raw); } catch { return NextResponse.json({ error: 'not JSON' }, { status: 400 }); }
  const msgs = incomingMessages(body).slice(0, 10);
  if (msgs.length) {
    after(async () => {
      const cfg = (await rpc('server_meta_messaging', {}, SR).catch(() => null)) as unknown as Cfg | null;
      if (!cfg) return;
      for (const m of msgs) {
        if (!cfg.on[m.channel]) continue;
        // a WhatsApp delivery for another number of the account is not ours to answer
        if (m.channel === 'whatsapp' && m.to && cfg.whatsapp_phone_id && m.to !== cfg.whatsapp_phone_id) continue;
        try {
          const o = await autoReply(m.channel, m.sender, m.text);
          const text = o.status === 'sent' && o.answer ? o.answer : o.handoff_text ?? null;
          if (!text) continue;
          const r = await sendMetaReply({ channel: m.channel, to: m.sender, text, version: cfg.graph_version, pageToken: cfg.page_token,
            whatsappToken: env().WHATSAPP_TOKEN ?? null, whatsappPhoneId: cfg.whatsapp_phone_id });
          if (!r.ok) console.warn(`meta auto-reply: not sent on ${m.channel} (${r.error ?? 'error'})`);
        } catch (e) { console.warn(`meta auto-reply: ${e instanceof Error ? e.message.slice(0, 120) : 'error'}`); }
      }
    });
  }
  return NextResponse.json({ received: msgs.length });
}
