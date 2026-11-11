import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { MarketingView, type MarketingData } from '@/features/marketplace/MarketingView';
import { scenePhotos } from '@/server/marketing-photos';
import { EventsAdmin, type EventRow } from '@/features/events/EventsAdmin';
import { SocialQueue } from '@/features/social/SocialQueue';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Marketing', path: '/staff/marketing', noindex: true, description: 'Facebook Marketplace from your own profile: today\'s posts, your own copy of each car, the replies and your log.' });

// Sales > Marketing (migration 0510; docs/runbooks/marketplace.md): the Marketplace tool for each salesperson's own Facebook
// profile, with no ad or copy posted twice across the team.
export default async function StaffMarketing({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, roles, user, aal }, sp] = await Promise.all([vaPage('/staff/marketing', ['sales']), searchParams]);
  const [data, events] = await Promise.all([read<MarketingData>('mp_team'), read<EventRow[]>('seo_events').catch(() => [] as EventRow[])]);
  const path = roles.sales_work_mode === 'in_person' ? 'sales_in_person' : 'sales_remote';
  return <>
    <MarketingView data={data} car={sp.car} academyHref={`/staff/academy/${path}/marketplace-with-claude`}
      scenes={(v) => scenePhotos(user.id, v, aal).then((x) => x.length > 0).catch(() => false)} />
    {/* 1860: Search Console clicks against the goal, read only */}
    <p className="small"><Link prefetch={false} className="link" href="/staff/marketing/seo" data-testid="staff-seo-link">SEO: clicks from Google, queries and indexing</Link></p>
    {/* release 36: the event pages, the same list as Admin > Marketing > Event pages */}
    <EventsAdmin rows={events} refresh={['/staff/marketing']} />
    {/* r36b (2220): the social post scheduler, the same as Admin > Marketing > Social drafts */}
    <SocialQueue />
  </>;
}
