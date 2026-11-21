import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { ContentCalendar, type CalData } from '@/features/social/ContentCalendar';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Content calendar', path: '/admin/marketing/calendar', noindex: true, description: 'The month of social posts: approve, edit, reject or regenerate each before anything is published.' });

// Admin > Marketing > Content calendar (release 48, migration 3263): the month of social posts written from the fleet.
// Nothing is published until a person approves it. Marketing staff have the same screen in their portal.
export default async function AdminContentCalendar({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/marketing/calendar'), searchParams]);
  const month = sp.month && /^\d{4}-(0[1-9]|1[0-2])$/.test(sp.month) ? sp.month : undefined;
  const d = await read<CalData>('social_calendar', { month: month ?? '' });
  return (<>
    <PageHead kicker="Marketing" title="Content calendar" purpose="A month of reels, carousels, photos and stories, written from the fleet. Nothing is published until someone approves it." />
    <ContentCalendar d={d} base="/admin/marketing/calendar" status={sp.status} />
  </>);
}
