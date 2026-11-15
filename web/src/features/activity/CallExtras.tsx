'use client';
import { useState } from 'react';
import type { ActivityItem } from './model';

// r48 (2995): a call on the Activity log (the renter's page, the booking's history): Play the recording, Quo's full
// summary when it has several lines, and the transcript (opened with one tap). Nothing shows for a call without them.
export function CallExtras({ x }: { x: NonNullable<ActivityItem['extra']> }) {
  const [open, setOpen] = useState(false);
  const recs = (x.recordings ?? []).filter((r) => r && typeof r.url === 'string' && (r.url.startsWith('/api/staff/phone/recording?') || /^https:\/\//.test(r.url)));
  const lines = (x.summary_lines ?? []).filter(Boolean);
  const transcript = (x.transcript ?? []).filter((d) => d && d.text);
  if (!recs.length && lines.length < 2 && !transcript.length && !x.voicemail_url) return null;
  return (
    <div className="small al-call" data-testid="activity-call-extras">
      {lines.length > 1 && <p data-testid="activity-call-summary"><b>Summary:</b> {lines.join(' ')}</p>}
      {recs.map((r, i) => r.source === 'site'
        ? <p key={i} className="stack"><audio controls preload="none" src={r.url} aria-label="Play the call recording" data-testid="activity-call-recording" /></p>
        : <p key={i}><a className="link" href={r.url} target="_blank" rel="noreferrer noopener" data-testid="activity-call-recording-link">Play the recording{recs.length > 1 ? ` ${i + 1}` : ''}</a></p>)}
      {x.voicemail_url && /^https:\/\//.test(x.voicemail_url) && <p><a className="link" href={x.voicemail_url} target="_blank" rel="noreferrer noopener">Play the voicemail</a></p>}
      {transcript.length > 0 && (
        <div>
          <button type="button" className="btn btn--quiet btn--sm" aria-expanded={open} onClick={() => setOpen(!open)} data-testid="activity-call-transcript-toggle">{open ? 'Hide the transcript' : 'Show the transcript'}</button>
          {open && <ol className="ph-transcript" data-testid="activity-call-transcript">{transcript.map((d, i) => <li key={i}>{d.who === 'call' ? null : <b>{d.who === 'us' ? 'CarmaCars' : 'Caller'}: </b>}{d.text}</li>)}</ol>}
        </div>)}
    </div>
  );
}
