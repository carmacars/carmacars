import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { PipelineBoard, type PipelineData } from '@/features/owner-pipeline/Board';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner pipeline', path: '/staff/owner-pipeline', noindex: true, description: 'Prospective owners by stage, with automatic follow-ups.' });

// The owner pipeline for staff working as Sales or Customer service (migration 0215): the same board as the Admin's,
// without the referral credits.
export default async function StaffOwnerPipeline() {
  const { read } = await vaPage('/staff/owner-pipeline', ['sales', 'cs']);
  const d = await read<PipelineData>('owner_pipeline');
  return (<>
    <PageHead title="Owner pipeline" purpose="Prospective owners by stage. Move a lead when you talk to them; follow-up emails stop by themselves when they reply or the stage changes." />
    <PipelineBoard d={d} refresh={['/staff/owner-pipeline']} />
  </>);
}
