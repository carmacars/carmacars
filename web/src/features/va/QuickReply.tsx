'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { vaAct } from '@/server/actions/va';

// A reply to the renter from an approved quick reply (05-va.md section 6): pick one, edit inside it, send.
// The database refuses a message that names a blocked term.
export function QuickReply({ booking, replies }: { booking: string; replies: Array<{ id: string; title: string; body: string }> }) {
  const router = useRouter();
  const [body, setBody] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  return (
    <form className="ad-form ad-form--narrow" data-testid="quick-reply" onSubmit={(e) => { e.preventDefault(); start(async () => {
      const r = await vaAct('send_message', { booking, body });
      setMsg(r.ok ? { ok: true, text: 'Sent. The renter sees it in their account.' } : { ok: false, text: r.message });
      if (r.ok) { setBody(''); router.refresh(); }
    }); }}>
      <div className="field"><label className="label" htmlFor="qr-pick">Quick reply</label>
        <select className="select" id="qr-pick" defaultValue="" onChange={(e) => { const q = replies.find((x) => x.id === e.target.value); if (q) setBody(q.body); }}>
          <option value="">Choose a reply</option>{replies.map((q) => <option key={q.id} value={q.id}>{q.title}</option>)}</select></div>
      <div className="field"><label className="label" htmlFor="qr-body">Message to the renter</label>
        <textarea className="input ad-textarea" id="qr-body" rows={4} maxLength={4000} value={body} onChange={(e) => setBody(e.target.value)} required /></div>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      <button className="btn btn--primary btn--sm" type="submit" disabled={pending || !body.trim()} data-testid="quick-reply-send">{pending ? 'Sending' : 'Send'}</button>
    </form>
  );
}
