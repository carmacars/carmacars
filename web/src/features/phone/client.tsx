'use client';
import { useState } from 'react';
import type { SessionDetail } from '../live/staff';

// The phone line for staff (migration 0085): the reads and actions of /api/staff/phone, their shapes, and how one call
// is shown (on the inbox and on every timeline).
export interface PhoneItem {
  id: string; thread_id: string; kind: 'call' | 'text'; direction: 'in' | 'out'; at: string; status: string | null; body: string | null;
  media: Array<{ url: string; type: string | null }>; missed: boolean; duration: number | null; answered_at: string | null;
  voicemail_text: string | null; voicemail_url: string | null; recordings: Array<{ url: string; duration: number | null }>;
  summary: string | null; summary_lines: string[] | null; summary_by: 'quo' | 'ai' | null; next_steps: string[] | null;
  transcript: Array<{ who: 'us' | 'them'; text: string }> | null; sms_kind: string | null; error_code: string | null; by: string | null; number: string; booking_number: string | null;
}
export interface PhoneThreadRow {
  id: string; number: string; display: string; who: string; name: string | null; match_kind: 'staff' | 'renter' | 'owner' | 'lead' | 'unknown'; manual: boolean;
  renter_id: string | null; owner_id: string | null; lead_id: string | null; staff_user_id: string | null; booking_id: string | null; booking_number: string | null;
  last_at: string | null; last: string | null; last_direction: 'in' | 'out' | null; unread: number; opted_out: boolean; missed: number; visitor_id: string | null;
}
export interface PhoneAi { ok: boolean; drafts: boolean; summaries: boolean; neurons: number; cap: number }
export interface PhoneInboxData { at: string; enabled: boolean; number: string; threads: PhoneThreadRow[]; unread: number; unknown: number; ai: PhoneAi }
export interface PhoneThreadData {
  thread: PhoneThreadRow; items: PhoneItem[]; ai: PhoneAi; visit: SessionDetail | null;
  renter: { id: string; name: string; email: string | null; mobile: string | null; sms_opt_out: boolean; bookings: Array<{ number: string; status: string; pickup_at: string }> } | null;
  owner: { id: string; name: string } | null; lead: { id: string; name: string | null; kind: string; status: string; email: string | null } | null; staff: { id: string; name: string } | null;
}
export interface PhoneTimelineData { items: PhoneItem[]; threads: Array<{ id: string; display: string; opted_out: boolean }> }

export async function phoneRead<T>(what: string, p: Record<string, string | number | undefined> = {}): Promise<T> {
  const q = new URLSearchParams({ what });
  for (const [k, v] of Object.entries(p)) if (v !== undefined && v !== '') q.set(k, String(v));
  const r = await fetch(`/api/staff/phone?${q}`, { cache: 'no-store', credentials: 'same-origin' });
  const j = (await r.json()) as T & { error?: string };
  if (!r.ok) throw new Error(j.error ?? 'Could not load');
  return j;
}
export async function phoneDo<T = { ok: boolean }>(action: string, p: Record<string, unknown> = {}): Promise<T> {
  const r = await fetch('/api/staff/phone', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ action, ...p }), credentials: 'same-origin' });
  const j = (await r.json()) as T & { error?: string };
  if (!r.ok && j.error) throw new Error(j.error);
  return j;
}

export const mins = (s: number | null) => (s === null ? '' : s < 60 ? `${s} s` : `${Math.floor(s / 60)} min ${s % 60 ? `${s % 60} s` : ''}`.trim());

/** One call: its length, the summary (Quo's, or the AI one-liner), next steps, voicemail, and the transcript and
 *  recording only when they exist (the line may not record calls). */
export function CallBody({ m }: { m: PhoneItem }) {
  const [open, setOpen] = useState(false);
  const transcript = (m.transcript ?? []).filter((d) => d.text);
  return (
    <div className="ph-callbody small">
      {!m.missed && m.duration !== null && <p className="muted">{mins(m.duration)}{m.status && m.status !== 'answered' && m.status !== 'completed' ? ` · ${m.status}` : ''}</p>}
      {m.summary && <p data-testid="call-summary"><b>{m.summary_by === 'ai' ? 'Summary (AI)' : 'Summary'}:</b> {m.summary_lines && m.summary_lines.length > 1 ? m.summary_lines.join(' ') : m.summary}</p>}
      {m.next_steps && m.next_steps.length > 0 && <p><b>Next steps:</b> {m.next_steps.join(' ')}</p>}
      {m.voicemail_text && <p><b>Voicemail:</b> {m.voicemail_text}</p>}
      {m.voicemail_url && <p><a className="link" href={m.voicemail_url} target="_blank" rel="noreferrer noopener">Play the voicemail</a></p>}
      {m.recordings.length > 0 && <p>{m.recordings.map((r, i) => <a key={i} className="link" href={r.url} target="_blank" rel="noreferrer noopener">Recording{m.recordings.length > 1 ? ` ${i + 1}` : ''}</a>)}</p>}
      {transcript.length > 0 && (
        <div><button type="button" className="btn btn--quiet btn--sm" aria-expanded={open} onClick={() => setOpen(!open)}>{open ? 'Hide the transcript' : 'Transcript'}</button>
          {open && <ol className="ph-transcript">{transcript.map((d, i) => <li key={i}><b>{d.who === 'us' ? 'CarmaCars' : 'Caller'}:</b> {d.text}</li>)}</ol>}</div>)}
    </div>
  );
}
