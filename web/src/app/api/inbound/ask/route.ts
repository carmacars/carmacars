import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import { jobAuthorized } from '@/server/job-auth';
import { parseMime, plainAddress } from '@/features/turo/email';
import { robotEmail } from '@/features/auto-reply/faq';
import { autoReply } from '@/server/auto-reply';

// AI auto-replies by email (release 36, migration 2110). The Worker's email handler (custom-worker.ts) posts each email sent
// to in.carmacars.ca that is not for trips@ here first, as raw MIME with the jobs' token. 404: not one of the inboxes of
// Program settings auto_reply_email_inboxes (the Worker then gives it to the Turo reader, as before). 200: handled; with
// {reply} the Worker answers the sender with message.reply (the email stays inside Cloudflare, from the address it was
// sent to). Robots, lists, bounces and our own addresses never get an answer. The message itself is never stored.
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };
const MAX = 1_000_000;

export async function POST(req: Request) {
  if (!(await jobAuthorized(req))) return new NextResponse('Forbidden', { status: 403 });
  const to = plainAddress(req.headers.get('x-envelope-to') ?? '').toLowerCase();
  const inboxes = ((await rpc('server_auto_reply_inboxes', {}, SR).catch(() => null)) as unknown as string[] | null) ?? [];
  const local = to.split('@')[0] ?? '';
  if (!to || !inboxes.includes(local)) return NextResponse.json({ handled: false }, { status: 404 });
  const raw = await req.text();
  if (!raw || raw.length > MAX) return NextResponse.json({ handled: true, error: 'empty or too large' });
  const m = parseMime(raw);
  const from = plainAddress(req.headers.get('x-envelope-from') ?? '') || plainAddress(m.from);
  if (!from || robotEmail(m.headers, `${m.from} ${from}`)) return NextResponse.json({ handled: true, skipped: 'automatic or our own' });
  // the question: the subject and the new part of the message (quoted replies and signatures cut)
  const body = m.text.split(/\n(?:>|On .{0,120}wrote:|-- ?\n|_{5,})/)[0]!.slice(0, 1500);
  const o = await autoReply('email', from.toLowerCase(), `${m.subject}\n${body}`.trim());
  const text = o.status === 'sent' && o.answer ? o.answer : o.handoff_text ?? null;
  if (!text) return NextResponse.json({ handled: true, status: o.status });
  return NextResponse.json({ handled: true, status: o.status, reply: { subject: m.subject, text: `${text}\n\n${o.status === 'sent' ? 'This answer was written automatically from our FAQ. Reply to this email and a person will help you.' : ''}`.trim(), in_reply_to: m.messageId || null } });
}
