'use client';
import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { opsAct } from '@/server/actions/ops';
import { emailProblem, pickSender, recipientChoices, SENDERS, senderChoices, usageLine, type Conversation, type Recipient, type Sender } from './email-choices';

// Email the renter (or the adjuster) from a booking (migration 0187): a subject and a message, optionally started from a
// quick reply. It goes through the email outbox like every email, at the customer priority, and is kept on the booking's
// messages and history with who sent it. On a booking an insurer pays, the adjuster can be written to and the sender can
// be Blind Spot Car Rental (insurance); the adjuster always hears from Blind Spot Car Rental.
export function EmailRenter({ c, refresh = [], initialTo = 'renter' }: { c: Conversation; refresh?: string[]; initialTo?: Recipient }) {
  const router = useRouter();
  const tos = recipientChoices(c);
  const [to, setTo] = useState<Recipient>(tos.some(([k]) => k === initialTo) ? initialTo : (tos[0]?.[0] ?? 'renter'));
  const [sender, setSender] = useState<Sender>(pickSender(c, to));
  const [subject, setSubject] = useState('');
  const [body, setBody] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  if (!tos.length) return <p className="small muted" data-testid="email-none">This booking has no renter to write to.</p>;
  const senders = senderChoices(c, to);
  const from = pickSender(c, to, sender);
  const address = to === 'adjuster' ? c.adjuster?.email : c.renter?.email;
  const usage = usageLine(c.usage);
  const problem = emailProblem(subject, body);
  return (
    <form className="ad-form ad-form--narrow" data-testid="email-renter" onSubmit={(e) => { e.preventDefault(); if (problem) { setMsg({ ok: false, text: problem }); return; } start(async () => {
      const r = await opsAct('booking_email', { booking: c.booking_id, to, sender: from, subject: subject.trim(), body }, refresh);
      setMsg(r.ok ? { ok: true, text: to === 'adjuster' ? 'Sent to the adjuster. It is in the list below.' : 'Sent. The renter gets it by email and in their account.' } : { ok: false, text: r.message });
      if (r.ok) { setSubject(''); setBody(''); router.refresh(); }
    }); }}>
      {tos.length > 1 && <div className="field"><label className="label" htmlFor="em-to">To</label>
        <select className="select" id="em-to" value={to} onChange={(e) => { const v = e.target.value as Recipient; setTo(v); setSender(pickSender(c, v, sender)); }} data-testid="email-to">
          {tos.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></div>}
      <div className="field"><label className="label" htmlFor="em-from">From</label>
        {senders.length > 1
          ? <select className="select" id="em-from" value={from} onChange={(e) => setSender(e.target.value as Sender)} data-testid="email-from">{senders.map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select>
          : <input className="input" id="em-from" value={SENDERS[from].label} readOnly data-testid="email-from" />}
        <span className="small muted">{SENDERS[from].address}{address ? `, to ${address}` : ''}. Replies come back to {from === 'blindspot' ? 'blindspotcarrental@carmacars.ca' : 'bookings@carmacars.ca'}.</span></div>
      {to === 'renter' && c.quick_replies.length > 0 && <div className="field"><label className="label" htmlFor="em-pick">Quick reply</label>
        <select className="select" id="em-pick" defaultValue="" onChange={(e) => { const q = c.quick_replies.find((x) => x.id === e.target.value); if (q) { setBody(q.body); if (!subject.trim()) setSubject(q.title); } }} data-testid="email-quick-reply">
          <option value="">Choose a reply</option>{c.quick_replies.map((q) => <option key={q.id} value={q.id}>{q.title}</option>)}</select></div>}
      <div className="field"><label className="label" htmlFor="em-subject">Subject</label>
        <input className="input" id="em-subject" maxLength={150} value={subject} onChange={(e) => setSubject(e.target.value)} placeholder={`Your booking ${c.booking}`} required /></div>
      <div className="field"><label className="label" htmlFor="em-body">Message</label>
        <textarea className="input ad-textarea" id="em-body" rows={6} maxLength={4000} value={body} onChange={(e) => setBody(e.target.value)} required /></div>
      <p className={`small ${usage.warn ? 'ad-late' : 'muted'}`} data-testid="email-usage">{usage.text}</p>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      <button className="btn btn--primary btn--sm" type="submit" disabled={pending || !!problem} data-testid="email-send">{pending ? 'Sending' : to === 'adjuster' ? 'Email the adjuster' : 'Email the renter'}</button>
    </form>
  );
}
