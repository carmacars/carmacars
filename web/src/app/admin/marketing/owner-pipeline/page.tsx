import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { PipelineBoard, type PipelineData } from '@/features/owner-pipeline/Board';
import { StageBoard } from '@/features/owner-stages/StageBoard';
import type { Board } from '@/features/owner-stages/model';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner pipeline', path: '/admin/marketing/owner-pipeline', noindex: true, description: 'Owners onboarding a car by step, and prospective owners by stage with automatic follow-ups.' });

// Admin > Marketing > Owner pipeline: the owners onboarding a car by step (r50, 4511), then the prospective owners (0217).
export default async function OwnerPipeline() {
  const { read } = await page('/admin/marketing/owner-pipeline');
  const [board, d] = await Promise.all([read<Board>('owner_stage_board').catch(() => null), read<PipelineData>('owner_pipeline')]);
  const refresh = ['/admin/marketing/owner-pipeline'];
  return (<>
    <PageHead kicker="Marketing" title="Owner pipeline" purpose="Every owner's car by step with its next action and whose turn it is; then every prospective owner by stage. Follow-ups go by themselves." />
    {board && <StageBoard b={board} base="/admin" refresh={refresh} />}
    <h2 className="d4">Prospective owners</h2>
    <PipelineBoard d={d} refresh={refresh} />
  </>);
}
