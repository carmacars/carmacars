import 'server-only';
import { env } from '@/lib/env';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { siteUrl } from '@/lib/site';
import { CALENDAR_SCOPE, meetLinkOf, meetRequest, type MeetCall } from '@/features/meet/event';

// Interview calls on Google Meet (release 37, migration 2303). An Admin connects the company's Google Calendar once
// (Admin > Hiring, "Connect Google Calendar"): OAuth with the site's Google client (GOOGLE_CALENDAR_CLIENT_ID/SECRET, else
// the reviews client GOOGLE_REVIEWS_CLIENT_ID/SECRET), calendar.events scope, offline access; the refresh token goes to the
// vault. The Worker's tick runs /api/jobs/meet while a call waits: a fresh access token, then each call's event is made,
// moved or deleted, and the Meet link handed to the database (public.server_hiring_meet_done). No token is ever logged.
const SR = { role: 'service_role' as const };
export const calendarCallbackUrl = () => `${siteUrl()}/api/google/calendar/callback`;

export function calendarKeys(): { id: string; secret: string } | null {
  const e = env();
  const id = e.GOOGLE_CALENDAR_CLIENT_ID || e.GOOGLE_REVIEWS_CLIENT_ID;
  const secret = e.GOOGLE_CALENDAR_CLIENT_SECRET || e.GOOGLE_REVIEWS_CLIENT_SECRET;
  return id && secret ? { id, secret } : null;
}

export function calendarConsentUrl(state: string): string | null {
  const k = calendarKeys();
  if (!k) return null;
  const q = new URLSearchParams({ client_id: k.id, redirect_uri: calendarCallbackUrl(), response_type: 'code', scope: `openid email ${CALENDAR_SCOPE}`,
    access_type: 'offline', prompt: 'consent', include_granted_scopes: 'true', state });
  return `https://accounts.google.com/o/oauth2/v2/auth?${q}`;
}

export async function calendarExchange(code: string, f: typeof fetch = fetch): Promise<{ refreshToken: string | null; email: string | null }> {
  const k = calendarKeys();
  if (!k) throw new Error('The Google app keys are not set');
  const r = await f('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ code, client_id: k.id, client_secret: k.secret, redirect_uri: calendarCallbackUrl(), grant_type: 'authorization_code' }), signal: AbortSignal.timeout(15_000) });
  const d = (await r.json().catch(() => ({}))) as { refresh_token?: string; id_token?: string; error?: string };
  if (!r.ok) throw new Error(`Google refused the code (${d.error ?? r.status})`);
  let email: string | null = null;
  try { const part = d.id_token?.split('.')[1]; if (part) email = (JSON.parse(atob(part.replace(/-/g, '+').replace(/_/g, '/'))) as { email?: string }).email ?? null; } catch { email = null; }
  return { refreshToken: d.refresh_token ?? null, email };
}

async function accessToken(refresh: string, f: typeof fetch): Promise<string> {
  const k = calendarKeys();
  if (!k) throw new Error('The Google app keys are not set');
  const r = await f('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: k.id, client_secret: k.secret, refresh_token: refresh, grant_type: 'refresh_token' }), signal: AbortSignal.timeout(15_000) });
  const d = (await r.json().catch(() => ({}))) as { access_token?: string; error?: string };
  if (!r.ok || !d.access_token) throw new Error(d.error === 'invalid_grant' ? 'Google no longer accepts the connection: connect Google Calendar again' : `Google refused the token (${d.error ?? r.status})`);
  return d.access_token;
}

interface Due { connected: boolean; calendar_id: string | null; refresh_token: string | null; calls: MeetCall[] }
const done = (p: Record<string, unknown>) => rpc('server_hiring_meet_done', { p: p as unknown as Json }, SR);

/** The job: every waiting call's event made, moved or deleted; a failure keeps the Jitsi link (the database's fallback). */
export async function runMeetJob(f: typeof fetch = fetch): Promise<{ ok: boolean; done: number; failed: number }> {
  const due = (await rpc('server_hiring_meet_due', {}, SR)) as unknown as Due;
  if (!due?.connected || !due.calls?.length) return { ok: true, done: 0, failed: 0 };
  let token: string;
  try {
    if (!due.refresh_token) throw new Error('The calendar connection has no token: connect Google Calendar again');
    token = await accessToken(due.refresh_token, f);
  } catch (e) {
    const error = e instanceof Error ? e.message : 'Google refused the token';
    for (const c of due.calls) await done({ id: c.id, ok: false, error }).catch(() => undefined);
    return { ok: false, done: 0, failed: due.calls.length };
  }
  let ok = 0, failed = 0;
  for (const c of due.calls.slice(0, 25)) {
    const req = meetRequest(c, due.calendar_id ?? 'primary');
    try {
      if (!req) { await done({ id: c.id, ok: c.sync === 'delete', error: 'Nothing to send' }); continue; }
      const r = await f(req.url, { method: req.method, headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
        body: req.body ? JSON.stringify(req.body) : undefined, signal: AbortSignal.timeout(20_000) });
      // a deleted event already gone is fine
      if (req.method === 'DELETE') { await done({ id: c.id, ok: r.ok || r.status === 404 || r.status === 410, error: r.ok ? null : `HTTP ${r.status}` }); ok++; continue; }
      const ev = (await r.json().catch(() => ({}))) as { id?: string; hangoutLink?: string; error?: { message?: string } };
      const link = r.ok ? meetLinkOf(ev) : null;
      if (!r.ok || !link || !ev.id) throw new Error(ev.error?.message?.slice(0, 200) ?? (r.ok ? 'Google made no Meet link' : `HTTP ${r.status}`));
      await done({ id: c.id, ok: true, event_id: ev.id, meet_url: link });
      ok++;
    } catch (e) {
      failed++;
      await done({ id: c.id, ok: false, error: e instanceof Error ? e.message : 'Google refused the event' }).catch(() => undefined);
    }
  }
  return { ok: failed === 0, done: ok, failed };
}
