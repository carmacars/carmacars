import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { Unanswered } from '@/features/unanswered/Unanswered';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Unanswered', path: '/admin/unanswered', noindex: true, description: 'Customer texts and missed calls waiting for an answer.' });

// 1061: every conversation answered.
export default async function AdminUnanswered() {
  const { user } = await page('/admin/unanswered');
  return (<><PageHead title="Unanswered" purpose="Every customer text with no reply and every missed call not called back, oldest first." /><Unanswered userId={user.id} base="/admin" /></>);
}
