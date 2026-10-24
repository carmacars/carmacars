import Link from 'next/link';
import { notFound } from 'next/navigation';
import { door, rolesOf } from '@/server/door';
import { consents } from '@/features/agreement/model';
import { AgreementView } from '@/features/agreement/AgreementView';
import { agreementFacts, blocksFor, unsignedFacts } from '@/server/portal/agreement';
import { SignNow } from './SignNow';
import type { SigningState } from './types';

// The page of "Sign now on this device" (migration 0130), for an Admin, an assistant or field staff.
export async function SignNowPage({ userId, aal, booking, base, backLabel }: { userId: string; aal?: 'aal1' | 'aal2' | null; booking: string; base: string; backLabel: string }) {
  const s = await door<SigningState | null>(userId, 'ops_read', 'in_person_signing', { booking }, aal).catch(() => null);
  if (!s?.booking_id) notFound();
  const facts = s.renter_user_id && s.agreement ? await agreementFacts(s.booking_id, s.renter_user_id).catch(() => null) : null;
  const roles = await rolesOf(userId);
  return (
    <div className="stack-lg">
      <p><Link prefetch={false} className="link" href={base}>{backLabel}</Link></p>
      <header className="stack"><p className="pt-kicker">Booking {s.booking_number}</p><h1 className="d2">Sign now on this device</h1>
        <p className="muted">Check the signer&apos;s name and original licence, then hand them this device. They read the agreements and sign; the record shows it was signed in person with you.</p></header>
      <SignNow s={s} base={base} staffName={roles.name ?? 'the staff member'} consents={consents()}
        agreement={facts ? <AgreementView blocks={blocksFor(unsignedFacts(facts))} /> : <p className="small muted">The agreement text is in the PDF on the booking.</p>} />
    </div>
  );
}
