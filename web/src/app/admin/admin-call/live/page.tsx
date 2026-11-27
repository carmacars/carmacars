import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { AdminCallLive } from '@/features/admin-call/AdminCallLive';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Admin call: live', path: '/admin/admin-call/live', noindex: true, description: 'The weekly Admin call, in the site.' });

// r50 hotfix 2 (5150): the Admin call in the site, the deck beside the video.
export default async function AdminCallLivePage() {
  const { user } = await page('/admin/admin-call/live');
  return (<><PageHead title="Admin call" purpose="The weekly call of the Admins, with the deck beside it." /><AdminCallLive userId={user.id} /></>);
}
