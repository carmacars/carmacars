'use client';
import './caller.css';
import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { dayClock } from '@/features/live/staff';
import { phoneDo, phoneRead } from '@/features/phone/client';
import { noteProblem, ROLE_WORDS, type CallerNote, type NotesRead } from './model';

// Renter notes (migration 0800): what staff noted about the renter, newest first, each with when and who. Admins and
// office staff add notes; nobody edits one; an Admin removes one with a reason (kept in the audit log). The renter
// page of Admin and of the staff portal, and the caller pop-up (compact: the last three and the box).
// r35 (0850): `formOnly` is the box alone, above the Activity log (which lists the notes); the page refreshes after a note.
export function RenterNotes({ renterId, initial, total, canRemove = false, callId, compact = false, formOnly = false }: {
  renterId: string; initial: CallerNote[]; total?: number; canRemove?: boolean; callId?: string; compact?: boolean; formOnly?: boolean;
}) {
  const router = useRouter();
  const [notes, setNotes] = useState(initial);
  const [body, setBody] = useState('');
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [added, setAdded] = useState(0);
  const shown = compact ? notes.slice(0, 3) : notes;
  const older = Math.max(0, (total !== undefined ? total + added : notes.length) - shown.length);
  const id = `rn-note-${renterId}${callId ? `-${callId}` : ''}`;

  async function add(e: React.FormEvent) {
    e.preventDefault();
    const problem = noteProblem(body);
    if (problem) { setMsg({ ok: false, text: problem }); return; }
    setBusy(true); setMsg(null);
    try {
      const r = await phoneDo<{ ok: boolean; note: CallerNote }>('renter_note_add', { renter_id: renterId, body: body.trim(), ...(callId ? { call_id: callId } : {}) });
      setNotes((n) => [r.note, ...n]); setBody(''); setAdded((a) => a + 1); setMsg({ ok: true, text: 'Note added.' });
      if (formOnly) router.refresh();
    } catch (err) { setMsg({ ok: false, text: err instanceof Error ? err.message : 'Not saved. Try again.' }); }
    finally { setBusy(false); }
  }
  async function remove(n: CallerNote) {
    const reason = window.prompt('Why remove this note? (kept in the audit log)');
    if (!reason || reason.trim().length < 3) return;
    try { await phoneDo('renter_note_remove', { id: n.id, reason: reason.trim() }); setNotes((x) => x.filter((y) => y.id !== n.id)); setMsg({ ok: true, text: 'Note removed.' }); }
    catch (err) { setMsg({ ok: false, text: err instanceof Error ? err.message : 'Not removed. Try again.' }); }
  }

  return (
    <div className={`rn${compact ? ' rn--compact' : ''}`} data-testid="renter-notes">
      <form className="rn-form" onSubmit={add}>
        <label className="small" htmlFor={id}>{compact ? 'Note about this call' : 'Add a note'}</label>
        <textarea id={id} className="input rn-body" rows={compact ? 2 : 3} maxLength={4000} value={body} onChange={(e) => setBody(e.target.value)}
          placeholder="What they asked, what you told them, what happens next" data-testid="renter-note-body" />
        <p className="rn-acts"><button type="submit" className="btn btn--primary btn--sm" disabled={busy} data-testid="renter-note-add">{busy ? 'Saving' : 'Add note'}</button>
          {msg && <span className={`small${msg.ok ? '' : ' rn-err'}`} role={msg.ok ? 'status' : 'alert'}>{msg.text}</span>}</p>
      </form>
      {formOnly ? null : shown.length === 0 ? <p className="small muted">No notes yet.</p> : (
        <ol className="rn-list" aria-label="Notes, newest first">{shown.map((n) => (
          <li key={n.id} data-testid="renter-note">
            <p className="rn-text">{n.body}</p>
            <p className="small muted" suppressHydrationWarning>{dayClock(n.at)} · {n.author} ({ROLE_WORDS[n.role] ?? n.role}){n.booking_number ? ` · ${n.booking_number}` : ''}{n.from_call ? ' · during a call' : ''}
              {canRemove && <> · <button type="button" className="link rn-remove" onClick={() => void remove(n)} data-testid="renter-note-remove">Remove</button></>}</p>
          </li>))}</ol>)}
      {compact && older > 0 && <p className="small muted">{older} older on the renter&apos;s page.</p>}
    </div>
  );
}

/** The notes read on demand (the Texts and calls thread of a renter): nothing is shown when the person may not read them. */
export function RenterNotesLoader({ renterId }: { renterId: string }) {
  const [data, setData] = useState<NotesRead | null>(null);
  useEffect(() => {
    let live = true;
    phoneRead<NotesRead>('renter_notes', { renter_id: renterId }).then((d) => { if (live) setData(d); }).catch(() => { /* not theirs to read */ });
    return () => { live = false; };
  }, [renterId]);
  if (!data) return null;
  return <div className="rn-thread" data-testid="thread-notes"><p className="small"><b>Notes</b></p><RenterNotes renterId={renterId} initial={data.notes} canRemove={data.can_remove} compact /></div>;
}
