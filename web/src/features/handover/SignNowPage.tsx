import Link from 'next/link';
import { notFound } from 'next/navigation';
import { door, rolesOf } from '@/server/door';
import { consents } from '@/features/agreement/model';
import { AgreementView } from '@/features/agreement/AgreementView';
import { blocksFor, openAgreement, unsignedBundle } from '@/server/portal/agreement';
import { keyTerms, loadBundle } from '@/server/agreements/bundle';
import { SignNow } from './SignNow';
import type { SigningState } from './types';

// The page of "Sign now on this device" (migration 0130), for an Admin, an assistant or field staff.
export async function SignNowPage({ userId, aal, booking, base, backLabel }: { userId: string; aal?: 'aal1' | 'aal2' | null; booking: string; base: string; backLabel: string }) {
  let s = await door<SigningState | null>(userId, 'ops_read', 'in_person_signing', { booking }, aal).catch(() => null);
  if (!s?.booking_id) notFound();
  let bundle = s.renter_user_id && s.agreement ? await loadBundle(s.booking_id, s.renter_user_id).catch(() => null) : null;
  // signed at pickup after the check-out readings (0154): the agreement is rendered again with them before anyone signs,
  // so the signed copy already holds the time, kilometres and fuel out (the same facts give the same document)
  if (bundle?.x.pickup && s.agreement?.status === 'open' && s.signers.every((g) => !g.signed_at) && s.renter_user_id) {
    try {
      await openAgreement(s.booking_id, s.renter_user_id);
      s = (await door<SigningState | null>(userId, 'ops_read', 'in_person_signing', { booking }, aal).catch(() => null)) ?? s;
      bundle = await loadBundle(s.booking_id, s.renter_user_id!).catch(() => bundle);
    } catch (e) { console.error('agreement with the pickup readings', s.booking_number, e instanceof Error ? e.message : e); }
  }
  const ub = bundle ? unsignedBundle(bundle) : null;
  // 0154: what the agreements would still print blank: fill it before they sign (the booking's Rental agreements card)
  const st = await door<{ missing: Array<{ key: string; label: string; required: boolean }> } | null>(userId, 'ops_read', 'agreement_state', { booking: s.booking_id }, aal).catch(() => null);
  const blank = (st?.missing ?? []).filter((m) => m.key !== 'company.hst_number');
  const roles = await rolesOf(userId);
  return (
    <div className="stack-lg">
      <p><Link prefetch={false} className="link" href={base}>{backLabel}</Link></p>
      <header className="stack"><p className="pt-kicker">Booking {s.booking_number}</p><h1 className="d2">Sign now on this device</h1>
        <p className="muted">Check the signer&apos;s name and original licence, then hand them this device. They read the agreements and sign; the record shows it was signed in person with you.</p></header>
      {blank.length > 0 && <p className="alert alert--warn" role="status" data-testid="sign-now-blank"><span className="alert__title">The agreement still has blanks</span>
        <span>{blank.map((m) => m.label).join('; ')}. Fill them on the booking&apos;s Rental agreements card first, so the signed copy has them. <Link prefetch={false} className="link" href={base}>{backLabel}</Link></span></p>}
      <SignNow s={s} base={base} staffName={roles.name ?? 'the staff member'} consents={consents()} terms={bundle ? keyTerms(bundle) : []}
        pickupPrinted={!!bundle?.x.pickup}
        agreement={ub ? <AgreementView blocks={blocksFor(ub.f, undefined, ub)} /> : <p className="small muted">The agreement text is in the PDF on the booking.</p>} />
    </div>
  );
}
