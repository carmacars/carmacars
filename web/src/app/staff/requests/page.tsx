import Link from '@/components/Link';
import { InfoTip } from '@/components/InfoTip';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { requestNow } from '@/features/va/lanes';
import { RequestsQueue, type Req } from '@/features/bookings-now/RequestsQueue';
import { bookingCards } from '@/server/bookings-now';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Requests and offers', path: '/staff/requests', noindex: true, description: 'Booking requests and offers out.' });

// The requests inbox (05-va.md section 4.1, 03-admin.md section 3): oldest first; each opens the review-and-offer screen.
export default async function VaRequests({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, user, aal, fn }, sp] = await Promise.all([vaPage('/staff/requests', ['cs', 'sales']), searchParams]);
  // the first reply target (Program settings, 5 minutes by default; 0057) marks a request waiting too long
  const [all, target] = await Promise.all([read<Req[]>('requests'), door<{ minutes: number; words: string }>(user.id, 'ops_read', 'reply_target', {}, aal).catch(() => ({ minutes: 5, words: '5 minutes' }))]);
  const state = sp.state ?? '';
  const cards = await bookingCards(user.id, all.map((r) => r.id), { va: fn, aal });
  const at = requestNow();
  return (
    <>
      <PageHead title="Requests and offers" kicker={`${all.filter((r) => r.status === 'requested').length} waiting · reply within ${target.words}`} purpose={<>The most urgent first. Open one to review it and send the offer.<InfoTip k="request_claim" topic="answering requests" /></>}>
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/staff/offers/new" data-testid="send-offer-link">Send an offer without a request</Link></PageHead>
      <RequestsQueue all={all} cards={cards} state={state} sp={sp} target={target} at={at} base="/staff" admin={false} sales={fn === 'sales'} />
    </>
  );
}
