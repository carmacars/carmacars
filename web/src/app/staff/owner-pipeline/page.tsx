import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { requireStaff } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { PipelineBoard, type PipelineData } from '@/features/owner-pipeline/Board';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner pipeline', path: '/staff/owner-pipeline', noindex: true, description: 'Prospective owners by stage, with automatic follow-ups.' });

// The owner pipeline for customer service (migration 0217): the same board as the Admin's, without the referral credits.
// Sales see only the owners they bring in, on My sales (0342): anyone who is not customer service goes there.
export default async function StaffOwnerPipeline() {
  const { roles } = await requireStaff('va', '/staff/owner-pipeline');
  if (!(roles.va_functions ?? (roles.va ? [roles.va] : [])).includes('cs')) redirect('/staff/my-sales#owners');
  const { read } = await vaPage('/staff/owner-pipeline', ['cs']);
  const d = await read<PipelineData>('owner_pipeline');
  return (<>
    <PageHead title="Owner pipeline" purpose="Prospective owners by stage. Move a lead when you talk to them; follow-up emails stop by themselves when they reply or the stage changes." />
    <PipelineBoard d={d} refresh={['/staff/owner-pipeline']} />
  </>);
}
