import { NextResponse } from 'next/server';
import { getCloudflareContext } from '@opennextjs/cloudflare';
import { bindingMessage, emailSendToken, mailProblem, type OutboxMail } from '@/server/email-send';

// One outbox email through Cloudflare Email Service (migration 0222): called by the send-outbox Edge Function only (the
// bearer token of src/server/email-send.ts). 503 when the Worker has no EMAIL binding (Email Service not set up yet,
// docs/changes/2026-11-03-cloudflare-email.md); any refusal is answered as such and the email goes through Resend.
export const dynamic = 'force-dynamic';
type EmailBinding = { send(m: Record<string, unknown>): Promise<unknown> };

export async function POST(req: Request) {
  const want = await emailSendToken();
  const got = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '');
  let d = want.length ^ got.length;
  for (let i = 0; i < want.length; i++) d |= want.charCodeAt(i) ^ (got.charCodeAt(i) || 0);
  if (d !== 0) return NextResponse.json({ error: 'forbidden' }, { status: 403 });
  const m = (await req.json().catch(() => null)) as OutboxMail | null;
  const bad = mailProblem(m);
  if (bad) return NextResponse.json({ error: `check ${bad}` }, { status: 400 });
  let b: EmailBinding | undefined;
  try { b = ((await getCloudflareContext({ async: true })).env as unknown as Record<string, EmailBinding | undefined>).EMAIL; } catch { b = undefined; }
  if (!b || typeof b.send !== 'function') return NextResponse.json({ error: 'no EMAIL binding on the Worker (Email Service not set up)' }, { status: 503 });
  try {
    const r = (await b.send(bindingMessage(m!))) as { messageId?: string; id?: string } | undefined;
    return NextResponse.json({ id: r?.messageId ?? r?.id ?? crypto.randomUUID() });
  } catch (e) {
    return NextResponse.json({ error: (e instanceof Error ? e.message : String(e)).slice(0, 300) }, { status: 502 });
  }
}
