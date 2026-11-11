import { pageMeta } from '@/features/seo/meta';
import { PageHead } from '@/features/admin/ui';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { EventsAdmin, type EventRow } from '@/features/events/EventsAdmin';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Event pages', path: '/admin/marketing/events', noindex: true, description: 'The Toronto and GTA events with a "Rent a car for" page.' });

// Admin > Marketing > Event pages (release 36, part 5; migration 2003). Sales sees the same list on Sales > Marketing.
export default async function AdminEvents() {
  const { user } = await page('/admin/marketing/events');
  const rows = await door<EventRow[]>(user.id, 'admin_read', 'seo_events', {}).catch(() => []);
  return (<>
    <PageHead title="Event pages" purpose='Toronto and GTA events, each with a "Rent a car for" page: add one, set its dates when announced, or switch a page off.' />
    <EventsAdmin rows={rows} refresh={['/admin/marketing/events']} />
  </>);
}
