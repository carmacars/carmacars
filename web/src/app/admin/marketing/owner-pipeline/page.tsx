import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { MarketingTabs } from '@/features/ads/MarketingTabs';
import { PipelineBoard, type PipelineData } from '@/features/owner-pipeline/Board';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner pipeline', path: '/admin/marketing/owner-pipeline', noindex: true, description: 'Prospective owners from the website, referrals, classified ads and staff, by stage, with automatic follow-ups.' });

// Admin > Marketing > Owner pipeline (migration 0217).
export default async function OwnerPipeline() {
  const { read } = await page('/admin/marketing/owner-pipeline');
  const d = await read<PipelineData>('owner_pipeline');
  return (<>
    <PageHead kicker="Marketing" title="Owner pipeline" purpose="Every prospective owner by stage: from the website form, a referral, a classified ad or added by hand. Follow-ups go by themselves." />
    <MarketingTabs current="/admin/marketing/owner-pipeline" />
    <PipelineBoard d={d} refresh={['/admin/marketing/owner-pipeline']} />
  </>);
}
