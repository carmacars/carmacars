'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { phoneDo } from '@/features/phone/client';

// Remove a renter note from the Activity log (an Admin, with a reason kept in the audit log; migration 0800's
// renter_note_remove). The log reads again after it.
export function NoteRemove({ id }: { id: string }) {
  const router = useRouter();
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  async function remove() {
    const reason = window.prompt('Why remove this note? (kept in the audit log)');
    if (!reason || reason.trim().length < 3) return;
    try { await phoneDo('renter_note_remove', { id, reason: reason.trim() }); setMsg({ ok: true, text: 'Note removed.' }); router.refresh(); }
    catch (err) { setMsg({ ok: false, text: err instanceof Error ? err.message : 'Not removed. Try again.' }); }
  }
  return <span className="small"><button type="button" className="link" onClick={() => void remove()} data-testid="renter-note-remove">Remove</button>
    {msg && <span role={msg.ok ? 'status' : 'alert'}> {msg.text}</span>}</span>;
}
