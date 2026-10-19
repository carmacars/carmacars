'use client';
import { useRouter } from 'next/navigation';
import { useAct } from '@/features/portal/useAct';
import { sendSetupEmail } from '@/server/actions/owner-billing';

// A car staff entered (migration 0067): the owner's set-up email, sent at approval; here sent again on request (with a
// new link to choose a password when the owner has not chosen one yet).
export function SetupEmail({ applicationId, sentAt }: { applicationId: string; sentAt: string | null }) {
  const router = useRouter();
  const a = useAct<{ note: string }>();
  return (
    <div className="stack" data-testid="setup-email">
      <p className="small">{sentAt ? `The set-up email went on ${new Date(sentAt).toLocaleString('en-CA', { timeZone: 'America/Toronto', dateStyle: 'medium', timeStyle: 'short' })}.` : 'The set-up email has not gone yet (the owner signs on paper, or it could not be sent).'}</p>
      <div className="row"><button type="button" className="btn btn--ghost btn--sm" disabled={a.pending} data-testid="setup-email-send"
        onClick={() => { if (window.confirm('Email the owner to review and sign?')) a.run(() => sendSetupEmail(applicationId), (r) => { if (r.ok) router.refresh(); }); }}>{sentAt ? 'Send the set-up email again' : 'Send the set-up email'}</button></div>
      {a.res && !a.res.ok && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      {a.res?.ok && <p className="alert alert--ok" role="status"><span>{a.res.data.note}</span></p>}
    </div>
  );
}
