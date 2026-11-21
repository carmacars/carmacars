import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { ContentCalendar, type CalData } from '@/features/social/ContentCalendar';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Content calendar', path: '/staff/marketing/calendar', noindex: true, description: 'The month of social posts: approve, edit, reject or regenerate each before anything is published.' });

// Marketing > Content calendar (release 48, migration 3263), for Sales, customer service and Fleet (the staff who may
// schedule social posts): the same screen as Admin > Marketing > Content calendar.
export default async function StaffContentCalendar({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user, aal }, sp] = await Promise.all([vaPage('/staff/marketing/calendar', ['sales', 'cs', 'fleet']), searchParams]);
  const month = sp.month && /^\d{4}-(0[1-9]|1[0-2])$/.test(sp.month) ? sp.month : undefined;
  const d = await door<CalData>(user.id, 'ops_read', 'social_calendar', { month: month ?? '' }, aal);
  return (<>
    <PageHead kicker="Marketing" title="Content calendar" purpose="A month of reels, carousels, photos and stories, written from the fleet. Nothing is published until someone approves it." />
    <ContentCalendar d={d} base="/staff/marketing/calendar" status={sp.status} />
  </>);
}
