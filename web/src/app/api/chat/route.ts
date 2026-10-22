import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { currentUser } from '@/server/portal/data';
import { answer, type VisitorMessageState } from '@/server/chat';
import { PAUSE } from '@/features/usage/model';

// Live chat (migration 0060), the visitor's side: open or continue a conversation, send a message (the assistant
// answers while no person has the chat), ask for a person, leave contact details, end the chat. The conversation's
// secret (token) lives in the visitor's browser; the database checks it, rate-limits and records everything. Reading
// new messages and the typing signal go straight from the browser to the database (public.chat_poll).
export const dynamic = 'force-dynamic';
const SR = { role: 'service_role' as const };
const H = { 'cache-control': 'no-store' };
const UUID = /^[0-9a-f-]{36}$/;
type Body = { action?: string; token?: string; body?: string; sid?: string; vid?: string; page?: string; slug?: string; greeting?: boolean; greeting_page?: string; device?: string;
  name?: string; email?: string; phone?: string; transcript?: boolean; after?: number };
const str = (v: unknown, n: number) => (typeof v === 'string' ? v.slice(0, n) : undefined);

export async function POST(req: Request) {
  const origin = req.headers.get('origin');
  if (origin && new URL(origin).host !== req.headers.get('host')) return NextResponse.json({ ok: false }, { status: 403, headers: H });
  const b = (await req.json().catch(() => null)) as Body | null;
  if (!b || typeof b.action !== 'string') return NextResponse.json({ ok: false, error: 'bad request' }, { status: 400, headers: H });
  const token = typeof b.token === 'string' && /^[0-9a-f]{64}$/.test(b.token) ? b.token : null;
  try {
    switch (b.action) {
      case 'open': {
        if (!b.vid || !UUID.test(b.vid)) return NextResponse.json({ ok: false, error: 'bad ids' }, { status: 400, headers: H });
        const user = await currentUser().catch(() => null);
        const p = { vid: b.vid, sid: b.sid && UUID.test(b.sid) ? b.sid : null, page: str(b.page, 300), slug: str(b.slug, 120), token, greeting: b.greeting ? 'true' : 'false', greeting_page: b.greeting ? str(b.greeting_page, 300) : undefined,
          device: str(b.device, 10), city: req.headers.get('cf-ipcity'), region: req.headers.get('cf-region-code'), country: req.headers.get('cf-ipcountry') };
        return NextResponse.json(await rpc('server_chat_open', { p: p as unknown as Json, p_user: user?.id }, SR), { headers: H });
      }
      case 'send': {
        if (!token) return NextResponse.json({ ok: false, error: 'not_found' }, { status: 400, headers: H });
        const text = str(b.body, 2000)?.trim() ?? '';
        if (!text) return NextResponse.json({ ok: false, error: 'empty' }, { status: 400, headers: H });
        const st = (await rpc('server_chat_visitor_message', { p_token: token, p_body: text }, SR)) as unknown as VisitorMessageState;
        if (!st.ok) return NextResponse.json(st, { headers: H });
        if (st.ai) {
          try { await answer(token, st, text); }
          catch (e) {
            console.error('chat assistant', e instanceof Error ? e.message.slice(0, 300) : e);
            await rpc('server_chat_handoff', { p_token: token, p_reason: 'the assistant is not available' }, SR);
          }
        }
        else if (st.status === 'ai') {
          // the day's AI allowance is used, or this chat had its share of AI replies: a person takes it
          // the day's included AI usage is used (the usage guard, 0080): the visitor reads that the assistant rests, never an error
          await rpc('server_chat_handoff', st.ai_reason === 'budget'
            ? { p_token: token, p_reason: 'the assistant is off for today (daily included AI usage reached)', p_message: PAUSE.chat }
            : { p_token: token, p_reason: 'a long conversation for the assistant' }, SR);
        }
        return NextResponse.json(await rpc('chat_poll', { p_token: token, p_after: Math.max(0, Number(b.after) || 0) }, SR), { headers: H });
      }
      case 'person': {
        if (!token) return NextResponse.json({ ok: false, error: 'not_found' }, { status: 400, headers: H });
        await rpc('server_chat_handoff', { p_token: token, p_reason: 'asked for a person' }, SR);
        return NextResponse.json(await rpc('chat_poll', { p_token: token, p_after: Math.max(0, Number(b.after) || 0) }, SR), { headers: H });
      }
      case 'contact': {
        if (!token) return NextResponse.json({ ok: false, error: 'not_found' }, { status: 400, headers: H });
        const r = await rpc('server_chat_contact', { p_token: token, p: { name: str(b.name, 120), email: str(b.email, 200), phone: str(b.phone, 40), transcript: Boolean(b.transcript) } as unknown as Json }, SR);
        return NextResponse.json(r, { headers: H });
      }
      case 'end': {
        if (!token) return NextResponse.json({ ok: false, error: 'not_found' }, { status: 400, headers: H });
        return NextResponse.json(await rpc('server_chat_end', { p_token: token }, SR), { headers: H });
      }
      default:
        return NextResponse.json({ ok: false, error: 'unknown action' }, { status: 400, headers: H });
    }
  } catch (e) {
    console.error('chat route', e instanceof Error ? e.message.slice(0, 300) : e);
    return NextResponse.json({ ok: false, error: 'unavailable' }, { status: 500, headers: H });
  }
}
