import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { TownhallLive } from '@/features/calls/TownhallLive';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Townhall call', path: '/admin/townhall/live', noindex: true, description: 'The weekly staff call, in the site: present the deck, see who is in.' });

// r50 (5010): the Admin presents the townhall: the call, the deck in sync for everyone, who is in and who is not.
export default async function AdminTownhallLive() {
  const { user } = await page('/admin/townhall/live');
  return (<><PageHead title="Townhall call" purpose="You present: your slide is everyone's. Attendance is recorded as people join and leave." /><TownhallLive userId={user.id} base="/admin" /></>);
}
