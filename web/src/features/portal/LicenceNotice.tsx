import Link from 'next/link';
import { rpc } from '@/lib/db/repo';
import { bookingPath } from '@/features/portal/status';
import type { LicenceStatus } from '@/features/handover/types';

// The driver's licence before the offer is accepted (migration 0130): front, back and the selfie, and the expiry after
// the return. Reused from an earlier booking while the licence is valid. The switch is in Program settings (on).
export interface LicenceState { required: boolean; selfie_required: boolean; drivers: Array<{ driver_id: string; role: string; name: string; licence: LicenceStatus }> }

export async function licenceState(bookingId: string, userId: string): Promise<LicenceState | null> {
  return (await rpc('server_licence_state', { p_booking: bookingId, p_by: userId }, { role: 'service_role' }).catch(() => null)) as unknown as LicenceState | null;
}

/** What the renter still has to send before accepting; null when nothing (or the switch is off). */
export function renterMissing(s: LicenceState | null): string[] | null {
  if (!s?.required) return null;
  const me = s.drivers.find((d) => d.role === 'renter');
  return me && !me.licence.complete ? me.licence.missing : null;
}

export function LicenceNotice({ number, missing, when }: { number: string; missing: string[] | null; when: 'request' | 'offer' | 'pay' }) {
  if (!missing?.length) return null;
  return (
    <section className="pt-card pt-card--next" aria-labelledby="pt-lic" data-testid="licence-needed">
      <h2 className="d4" id="pt-lic">Upload your driver&apos;s licence</h2>
      <p>{when === 'request' ? 'We need it to check your request: the front and back of your licence and a selfie holding it. It takes a minute.'
        : when === 'offer' ? 'Before you accept the offer: the front and back of your licence and a selfie holding it.'
        : 'Before you pay: the front and back of your licence and a selfie holding it.'}</p>
      <p className="small">Still needed: {missing.join(', ')}.</p>
      <p><Link prefetch={false} className="btn btn--primary" href={bookingPath(number, 'verify')} data-testid="licence-upload-link">Upload your licence</Link></p>
    </section>
  );
}
