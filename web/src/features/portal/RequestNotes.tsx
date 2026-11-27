'use client';
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { addRequestNote, type RequestNote } from '@/server/actions/portal';
import { useAct } from './useAct';
import { WhyDisabled } from '@/components/WhyDisabled';

const at = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));

// 5132: the renter's notes on their open request (a flight, a question, a change of plan). Our team sees each one on the
// request at once; the request itself is unchanged.
export function RequestNotes({ number, notes: first }: { number: string; notes: RequestNote[] }) {
  const id = useId();
  const router = useRouter();
  const [notes, setNotes] = useState(first);
  const [text, setText] = useState('');
  const a = useAct<RequestNote[]>();
  const why = !text.trim() ? 'Write your note first' : null;
  return (
    <div className="stack" data-testid="request-notes-card">
      {notes.length > 0 && <ul className="pt-notes" aria-label="Your notes">{notes.map((n) => <li key={n.id}><span className="small muted">{at(n.at)}</span><p>{n.body}</p></li>)}</ul>}
      <form className="stack" onSubmit={(e) => { e.preventDefault(); if (why) return; a.run(() => addRequestNote(number, text), (r) => { if (r.ok) { setNotes(r.data); setText(''); router.refresh(); } }); }}>
        <div className="field"><label className="label" htmlFor={`${id}-note`}>Add a note to your request</label>
          <textarea className="input" id={`${id}-note`} rows={3} maxLength={1000} value={text} onChange={(e) => setText(e.target.value)} data-testid="request-note-input" aria-describedby={`${id}-hint`} />
          <p className="hint" id={`${id}-hint`}>A flight number, a question or a change of plan. Our team sees it on your request right away.</p></div>
        {a.res && !a.res.ok && <p className="error" role="alert">{a.res.message}</p>}
        {a.res?.ok && <p className="small" role="status">Added. Our team has it.</p>}
        <div><button type="submit" className="btn btn--primary btn--sm" disabled={a.pending || !!why} aria-busy={a.pending} aria-describedby={`${id}-why`} data-testid="request-note-add">{a.pending ? 'Adding' : 'Add the note'}</button><WhyDisabled id={`${id}-why`} why={why} /></div>
      </form>
    </div>
  );
}
