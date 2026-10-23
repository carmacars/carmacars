'use client';
import { useRouter } from 'next/navigation';
import { dismissLinkedNotice } from '@/server/actions/portal';
import { useAct } from './useAct';

// What was added to the account when its email address was confirmed (migration 0040): earlier booking requests made
// with the address, and places as an additional driver on someone else's booking.
export function LinkedNotice({ bookings, drivers }: { bookings: string[]; drivers: number }) {
  const router = useRouter();
  const a = useAct();
  return (
    <div className="alert alert--ok" role="status" data-testid="linked-notice">
      <span className="alert__title">We found earlier requests made with your email</span>
      {/* a long list of numbers is a wall of text (portal cleanup, October 23, 2026): past three, the count and the list folded */}
      <span>{bookings.length > 0 && bookings.length <= 3 ? `${bookings.length === 1 ? 'Request' : 'Requests'} ${bookings.join(', ')} ${bookings.length === 1 ? 'is' : 'are'} now in your trips. ` : ''}
        {bookings.length > 3 ? <>{bookings.length} requests are now in your trips. <details className="pt-inline-more"><summary>Show the numbers</summary>{bookings.join(', ')}</details></> : null}
        {drivers > 0 ? `You are named as a driver on ${drivers === 1 ? 'a booking' : `${drivers} bookings`}; see below. ` : ''}</span>
      <button className="btn btn--quiet btn--sm" type="button" disabled={a.pending} onClick={() => a.run(() => dismissLinkedNotice(), (r) => { if (r.ok) router.refresh(); })}>Got it</button>
    </div>
  );
}
