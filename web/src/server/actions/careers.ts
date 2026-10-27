'use server';
import { verifyTurnstile } from '@/integrations/turnstile';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { requestMeta } from '@/server/request';
import { sourceOf, UTM_KEYS } from '@/features/careers/model';

// Careers (migration 0173). The application goes to public.server_hiring_apply after Turnstile, as the server: the database
// checks every answer, scores it, and sends the invitation, the referral, the decline or the confirmation. The booking page
// books, moves and cancels with the candidate's personal link (the token is the key; nothing else identifies them).
const SR = { role: 'service_role' as const };
const TOKEN = /^[0-9a-f]{64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export interface ApplyInput { role: string; full_name: string; email: string; phone: string; profile_name?: string; answers: Record<string, string | string[]>; src?: string | null;
  utm?: Record<string, string>; ref?: string | null; turnstile?: string | null; website?: string }
export type ApplyResult = { ok: true; outcome: 'invited' | 'received' | 'declined' | 'referred'; token?: string | null; other_role?: string; other_title?: string }
  | { ok: false; code: string; message: string; errors?: Record<string, string> };

export async function submitApplication(i: ApplyInput): Promise<ApplyResult> {
  // a filled honeypot (a field people never see) is a bot: answered as received, nothing saved
  if (i.website) return { ok: true, outcome: 'received' };
  if (!/^[a-z0-9-]{2,60}$/.test(i.role ?? '')) return { ok: false, code: 'invalid', message: 'This role is not open.' };
  const meta = await requestMeta();
  if (!(await verifyTurnstile(typeof i.turnstile === 'string' ? i.turnstile : null, meta.ip))) return { ok: false, code: 'turnstile', message: 'We could not confirm you are not a bot. Reload the page and try again.' };
  const answers: Record<string, string | string[]> = {};
  for (const [k, v] of Object.entries(i.answers ?? {}).slice(0, 40)) {
    if (!/^[a-z_]{1,40}$/.test(k)) continue;
    answers[k] = Array.isArray(v) ? v.slice(0, 20).map((x) => String(x).slice(0, 200)) : String(v ?? '').slice(0, 2100);
  }
  const utm: Record<string, string> = {};
  for (const k of UTM_KEYS) if (i.utm?.[k]) utm[k] = String(i.utm[k]).slice(0, 100);
  try {
    const r = (await rpc('server_hiring_apply', { p: { role: i.role, full_name: String(i.full_name ?? '').slice(0, 200), email: String(i.email ?? '').slice(0, 200), phone: String(i.phone ?? '').slice(0, 60),
      profile_name: String(i.profile_name ?? '').slice(0, 200), source: sourceOf(i.src), utm, answers, ref: i.ref && TOKEN.test(i.ref) ? i.ref : null } as unknown as Json, p_ip: meta.ip ?? undefined }, SR)) as unknown as
      { ok: boolean; error?: string; errors?: Record<string, string>; outcome?: 'invited' | 'received' | 'declined' | 'referred'; token?: string | null; other_role?: string; other_title?: string };
    if (!r.ok) {
      if (r.error === 'invalid') return { ok: false, code: 'invalid', message: 'Check the highlighted answers.', errors: r.errors ?? {} };
      if (r.error === 'rate_limited') return { ok: false, code: 'rate_limited', message: 'Too many applications from this connection. Please try again later.' };
      if (r.error === 'closed') return { ok: false, code: 'closed', message: 'This role is no longer open.' };
      return { ok: false, code: 'refused', message: 'We could not send that. Please try again.' };
    }
    return { ok: true, outcome: r.outcome ?? 'received', token: r.outcome === 'invited' || r.outcome === 'referred' ? r.token ?? null : null, other_role: r.other_role, other_title: r.other_title };
  } catch {
    return { ok: false, code: 'db', message: 'We could not send that. Please try again in a minute.' };
  }
}

export type BookResult = { ok: true; starts_at?: string; mode?: string; meet_url?: string | null; moved?: boolean } | { ok: false; message: string };
const BOOK_ERRORS: Record<string, string> = {
  taken: 'Someone just took that time. Please pick another one.', too_late: 'That time is too soon to book. Please pick a later one.',
  no_slot: 'That time is no longer available.', not_open: 'This link can no longer book a call. Reply to our email if you need help.', not_found: 'This link is not valid.',
  not_booked: 'There is no booked call to cancel.'
};

export async function bookSlot(token: string, slot: string): Promise<BookResult> {
  if (!TOKEN.test(token ?? '') || !UUID.test(slot ?? '')) return { ok: false, message: 'Choose a time.' };
  try {
    const r = (await rpc('server_hiring_book', { p_token: token, p_slot: slot }, SR)) as unknown as { ok: boolean; error?: string; starts_at?: string; mode?: string; meet_url?: string | null; moved?: boolean };
    if (!r.ok) return { ok: false, message: BOOK_ERRORS[r.error ?? ''] ?? 'We could not book that time. Please try again.' };
    return { ok: true, starts_at: r.starts_at, mode: r.mode, meet_url: r.meet_url, moved: r.moved };
  } catch { return { ok: false, message: 'We could not book that time. Please try again.' }; }
}

export async function cancelBooking(token: string): Promise<BookResult> {
  if (!TOKEN.test(token ?? '')) return { ok: false, message: 'This link is not valid.' };
  try {
    const r = (await rpc('server_hiring_cancel', { p_token: token }, SR)) as unknown as { ok: boolean; error?: string };
    return r.ok ? { ok: true } : { ok: false, message: BOOK_ERRORS[r.error ?? ''] ?? 'We could not cancel the call.' };
  } catch { return { ok: false, message: 'We could not cancel the call. Please try again.' }; }
}
