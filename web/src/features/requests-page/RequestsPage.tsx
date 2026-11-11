import Link from '@/components/Link';
import { InfoTip } from '@/components/InfoTip';
import { PageHeader, SegTabs } from '@/components/ui';
import { requestNow } from '@/features/va/lanes';
import { RequestsQueue, type Req } from '@/features/bookings-now/RequestsQueue';
import { ChauffeurRequests, STATUSES as CH_STATUSES, type ChauffeurData } from '@/features/chauffeur/ChauffeurRequests';
import { bookingCards } from '@/server/bookings-now';
import type { PageCtx } from '@/features/shared-pages/context';
import { portalBase } from '@/features/shared-pages/viewer';

// r31 "Simple": one request inbox for Admin and staff (03-admin.md section 3, 05-va.md section 4.1): the most urgent
// first; each opens the booking's review and offer. An Admin also has the Chauffeur tab; customer service and Sales
// write a quote from here. The queue's claim and timer are the shared RequestsQueue's.
export async function RequestsPage({ ctx, sp }: { ctx: PageCtx; sp: Record<string, string | undefined> }) {
  const { viewer, read, user, aal, ops } = ctx;
  const admin = viewer.role === 'admin';
  const fn = viewer.role === 'staff' ? viewer.fn : null;
  const base = portalBase(viewer);
  // Release 26: Chauffeur is a tab here for an Admin (was Bookings > Chauffeur, /admin/chauffeur, which lands here)
  if (admin && sp.tab === 'chauffeur') {
    const status = CH_STATUSES.includes(sp.status ?? '') ? sp.status! : undefined;
    const data = await ops<ChauffeurData>('chauffeur_requests', status ? { status } : {});
    return (
      <>
        {/* r35 UX: the same head as Bookings (the style guide's PageHeader and segmented tabs) */}
        <PageHeader title="Requests and offers" lead={`${data.counts.new ?? 0} chauffeur requests new`} actions={<Link prefetch={false} className="btn btn--ghost btn--sm" href="/chauffeur">The public chauffeur page</Link>}
          tabs={<RequestTabs current="chauffeur" />} />
        <ChauffeurRequests data={data} base="/admin/requests?tab=chauffeur" status={status} />
      </>
    );
  }
  // the first reply target (Program settings, 5 minutes by default; 0057) marks a request waiting too long
  const [all, target] = await Promise.all([read<Req[]>('requests'), ops<{ minutes: number; words: string }>('reply_target', {}).catch(() => ({ minutes: 5, words: '5 minutes' }))]);
  const state = sp.state ?? '';
  const cards = await bookingCards(user.id, all.map((r) => r.id), admin ? undefined : { va: fn, aal });
  const at = admin ? new Date().getTime() : requestNow();
  const waiting = all.filter((r) => r.status === 'requested').length;
  return (
    <>
      {/* r35 UX: the same head as Bookings (the style guide's PageHeader and segmented tabs) */}
      <PageHeader title="Requests and offers"
        lead={<>{admin ? `${waiting} waiting · first reply target ${target.words}` : `${waiting} waiting · reply within ${target.words}`}. {admin ? 'The most urgent first: the longest wait, then offers waiting for payment, then offers out by expiry.' : <>The most urgent first. Open one to review it and send the offer.<InfoTip k="request_claim" topic="answering requests" /></>}</>}
        actions={<>
          {!admin && <Link prefetch={false} className="btn btn--ghost btn--sm" href="/staff/quotes/new" data-testid="new-quote-link">New quote</Link>}
          <Link prefetch={false} className="btn btn--primary btn--sm" href={`${base}/offers/new`} data-testid="send-offer-link">Send an offer without a request</Link></>}
        tabs={admin ? <RequestTabs current="cars" /> : undefined} />
      <RequestsQueue all={all} cards={cards} state={state} sp={sp} target={target} at={at} base={base} admin={admin} {...(admin ? {} : { sales: fn === 'sales' })} />
    </>
  );
}

function RequestTabs({ current }: { current: 'cars' | 'chauffeur' }) {
  return <SegTabs label="Requests and offers" current={current === 'cars' ? '/admin/requests' : '/admin/requests?tab=chauffeur'}
    items={[{ href: '/admin/requests', label: 'Car rentals' }, { href: '/admin/requests?tab=chauffeur', label: 'Chauffeur' }]} />;
}
