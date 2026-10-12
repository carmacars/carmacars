'use client';
import { useRouter } from 'next/navigation';
import { prepareAgreement } from '@/server/actions/portal';
import { useAct } from './useAct';

export function PrepareAgreement({ number }: { number: string }) {
  const router = useRouter();
  const a = useAct();
  return (
    <section className="pt-card pt-card--next">
      <h2 className="d4">Your agreement is not ready yet</h2>
      <p>We prepare it from your approved offer.</p>
      {a.res && !a.res.ok && <p className="alert alert--error" role="alert"><span>{a.res.message}</span></p>}
      <p><button className="btn btn--primary" type="button" disabled={a.pending} onClick={() => a.run(() => prepareAgreement(number), (r) => { if (r.ok) router.refresh(); })}>{a.pending ? 'Preparing' : 'Prepare my agreement'}</button></p>
    </section>
  );
}
