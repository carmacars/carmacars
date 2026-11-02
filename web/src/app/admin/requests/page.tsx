import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead, Tabs } from '@/features/admin/ui';
import { RequestsQueue, type Req } from '@/features/bookings-now/RequestsQueue';
import { bookingCards } from '@/server/bookings-now';
import { ChauffeurRequests, STATUSES as CH_STATUSES, type ChauffeurData } from '@/features/chauffeur/ChauffeurRequests';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Requests and offers', path: '/admin/requests', noindex: true, description: 'Booking requests and offers, oldest first, and chauffeur requests.' });

// The request inbox (03-admin.md section 3; Release 26 part 2): one queue by urgency until each is offered or declined.
export default async function Requests({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, user }, sp] = await Promise.all([page('/admin/requests'), searchParams]);
  // Release 26: Chauffeur is a tab here (was Bookings > Chauffeur, /admin/chauffeur, which now lands here)
  if (sp.tab === 'chauffeur') {
    const status = CH_STATUSES.includes(sp.status ?? '') ? sp.status! : undefined;
    const data = await door<ChauffeurData>(user.id, 'ops_read', 'chauffeur_requests', status ? { status } : {});
    return (
      <>
        <PageHead title="Requests and offers" kicker={`${data.counts.new ?? 0} chauffeur requests new`}><Link prefetch={false} className="btn btn--ghost btn--sm" href="/chauffeur">The public chauffeur page</Link></PageHead>
        <RequestTabs current="chauffeur" />
        <ChauffeurRequests data={data} base="/admin/requests?tab=chauffeur" status={status} />
      </>
    );
  }
  // the first reply target (Program settings, 5 minutes by default; 0057) marks a request waiting too long
  const [all, target] = await Promise.all([read<Req[]>('requests'), door<{ minutes: number; words: string }>(user.id, 'ops_read', 'reply_target').catch(() => ({ minutes: 5, words: '5 minutes' }))]);
  const state = sp.state ?? '';
  const cards = await bookingCards(user.id, all.map((r) => r.id));
  const at = new Date().getTime();
  return (
    <>
      <PageHead title="Requests and offers" kicker={`${all.filter((r) => r.status === 'requested').length} waiting · first reply target ${target.words}`} purpose="The most urgent first: the longest wait, then offers waiting for payment, then offers out by expiry.">
        <Link prefetch={false} className="btn btn--primary btn--sm" href="/admin/offers/new" data-testid="send-offer-link">Send an offer without a request</Link></PageHead>
      <RequestTabs current="cars" />
      <RequestsQueue all={all} cards={cards} state={state} sp={sp} target={target} at={at} base="/admin" admin />
    </>
  );
}

function RequestTabs({ current }: { current: 'cars' | 'chauffeur' }) {
  return <Tabs label="Requests and offers" current={current === 'cars' ? '/admin/requests' : '/admin/requests?tab=chauffeur'}
    items={[['/admin/requests', 'Car rentals'], ['/admin/requests?tab=chauffeur', 'Chauffeur']]} />;
}
