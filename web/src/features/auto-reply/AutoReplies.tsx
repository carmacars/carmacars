'use client';
import { useEffect, useState } from 'react';
import { staffRead } from '@/server/actions/staff-tools';

// Release 36 (2110): what the AI auto-replies did: today's answers by outcome and the last questions with what was sent or
// why a person must answer. On Settings > Program (Admins) and under Renter messages (customer service).
type Row = { id: string; channel: string; question: string | null; answer: string | null; status: 'sent' | 'queued' | 'handoff' | 'skipped' | 'failed'; reason: string | null; at: string };
type Data = { today: Record<string, number>; rows: Row[] };
const CH: Record<string, string> = { sms: 'Text', email: 'Email', chat: 'Chat', whatsapp: 'WhatsApp', messenger: 'Messenger', instagram: 'Instagram' };
const ST: Record<Row['status'], string> = { sent: 'Answered', queued: 'Answer held for the quiet hours', handoff: 'For a person', skipped: 'Not answered', failed: 'Failed' };
const when = (s: string) => new Date(s).toLocaleString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });

export function AutoReplies({ limit = 20 }: { limit?: number }) {
  const [d, setD] = useState<Data | null>(null);
  useEffect(() => { let on = true; void staffRead<Data>('auto_replies', { limit }).then((r) => { if (on && r.ok) setD(r.data); }); return () => { on = false; }; }, [limit]);
  if (!d) return null;
  const t = d.today;
  return (
    <div className="stack" data-testid="auto-replies">
      <p className="small">Today: {t.sent ?? 0} answered, {t.queued ?? 0} held for the quiet hours, {t.handoff ?? 0} for a person, {t.skipped ?? 0} not answered (off, the daily cap, or the free AI allowance used).
        Answers come only from the FAQ (Settings &gt; Site content); a question it does not cover is left for staff.</p>
      {d.rows.length ? <ul className="stack small" aria-label="Recent automatic answers">{d.rows.map((r) => (
        <li key={r.id} data-status={r.status}>
          <b>{CH[r.channel] ?? r.channel}</b> · {when(r.at)} · {ST[r.status]}{r.reason && r.status !== 'sent' ? ` (${r.reason})` : ''}
          {r.question && <><br /><span className="muted">Q: {r.question.slice(0, 200)}</span></>}
          {r.answer && <><br />A: {r.answer.slice(0, 300)}</>}
        </li>))}</ul> : <p className="small muted">No questions yet.</p>}
    </div>
  );
}
