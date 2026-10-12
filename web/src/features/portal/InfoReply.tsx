'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { replyInfo } from '@/server/actions/portal';
import { useAct } from './useAct';

export function InfoReply({ number, requestId }: { number: string; requestId: string }) {
  const router = useRouter();
  const a = useAct();
  const [text, setText] = useState('');
  const id = `pt-reply-${requestId.slice(0, 8)}`;
  if (a.res?.ok) return <p role="status" className="alert alert--ok"><span>Thank you. Your answer is with our team.</span></p>;
  return (
    <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => replyInfo(number, requestId, text), (r) => { if (r.ok) router.refresh(); }); }}>
      <div className={`field${a.err('reply') ? ' has-error' : ''}`}>
        <label className="label" htmlFor={id}>Your answer</label>
        <textarea className="textarea" id={id} value={text} onChange={(e) => setText(e.target.value)} maxLength={2000} aria-invalid={!!a.err('reply') || undefined} aria-describedby={`${id}-err`} />
        <p className="error" role="alert" id={`${id}-err`}>{a.err('reply') ?? (a.res && !a.res.ok ? a.res.message : '')}</p>
      </div>
      <button className="btn btn--primary" type="submit" disabled={a.pending}>{a.pending ? 'Sending' : 'Send answer'}</button>
    </form>
  );
}
