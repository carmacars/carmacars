'use client';
import { useId, useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { answerApplication } from '@/server/actions/applications';

// The owner portal's task when CarmaCars asked for something on an application (migration 0054): what is needed,
// the note, and one box to answer (or say where the documents were uploaded).
export interface AppTask { id: string; application_number: string; requested_at: string; message: string | null; items: string[] }

export function ApplicationTask({ t }: { t: AppTask }) {
  const router = useRouter();
  const a = useAct();
  const uid = `at-${useId().replace(/[^\w-]/g, '')}`;
  const [reply, setReply] = useState('');
  if (a.res?.ok) return <p className="alert alert--ok" role="status" data-testid="owner-app-answered"><span className="alert__title">Thank you</span><span>We have your answer and review it within 1 business day.</span></p>;
  return (
    <section className="pt-card pt-card--next stack" aria-labelledby={`${uid}-h`} data-testid="owner-app-task">
      <p className="pt-kicker">Application {t.application_number}</p>
      <h2 className="d3" id={`${uid}-h`}>We need a little more</h2>
      <ul>{t.items.map((i) => <li key={i}>{i}</li>)}</ul>
      {t.message && <p className="small"><b>Note from our team:</b> {t.message}</p>}
      <p className="small muted">Upload documents on your vehicle&apos;s page, then tell us here. You can also reply to our email with them attached.</p>
      <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); a.run(() => answerApplication(t.id, reply), () => router.refresh()); }}>
        <div className={`field${a.err('reply') ? ' has-error' : ''}`}><label className="label" htmlFor={`${uid}-r`}>Your answer</label>
          <textarea className="input" id={`${uid}-r`} rows={3} value={reply} onChange={(e) => setReply(e.target.value)} aria-invalid={!!a.err('reply') || undefined} data-testid="owner-app-reply" />
          <p className="error" role="alert">{a.err('reply') ?? ''}</p></div>
        <div className="row"><button className="btn btn--primary" type="submit" disabled={a.pending} data-testid="owner-app-send">{a.pending ? 'Sending' : 'Send my answer'}</button></div>
        {a.res && !a.res.ok && !a.res.fieldErrors && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      </form>
    </section>
  );
}
