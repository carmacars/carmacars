import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { Unanswered } from '@/features/unanswered/Unanswered';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Unanswered', path: '/staff/unanswered', noindex: true, description: 'Customer texts and missed calls waiting for an answer.' });

// 1061: customer service's queue of conversations waiting for an answer.
export default async function StaffUnanswered() {
  const { user, aal } = await vaPage('/staff/unanswered', ['cs']);
  return (<><PageHead title="Unanswered" purpose="Every customer text with no reply and every missed call not called back, oldest first." /><Unanswered userId={user.id} aal={aal} base="/staff" /></>);
}
