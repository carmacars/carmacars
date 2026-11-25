import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { PipelineBoard, type PipelineData } from '@/features/owner-pipeline/Board';
import { StageBoard } from '@/features/owner-stages/StageBoard';
import type { Board } from '@/features/owner-stages/model';
import { GuideMeLink } from '@/features/guide-me/GuideMeLink';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner pipeline', path: '/staff/owner-pipeline', noindex: true, description: 'Owners onboarding a car by step, and prospective owners by stage.' });

// The owner pipeline. r50 (4511): first the owners onboarding a car, by step (Sales: the owners they brought in; customer
// service and Fleet: every owner), with days in step, the next action and whose it is, the nudge and the call script. Then,
// for customer service, the prospective owners of 0217 (Sales see theirs on My sales).
export default async function StaffOwnerPipeline() {
  const { read, fn } = await vaPage('/staff/owner-pipeline', ['sales', 'cs', 'fleet']);
  const [board, d] = await Promise.all([read<Board>('owner_stage_board').catch(() => null), fn === 'cs' ? read<PipelineData>('owner_pipeline') : Promise.resolve(null)]);
  const refresh = ['/staff/owner-pipeline'];
  return (<>
    <PageHead title="Owner pipeline" purpose="Every owner's car by step, whose turn it is and the one next action. Nudge the owner in one tap; the call script of each step is on the card.">
      <Link prefetch={false} className="btn btn--ghost btn--sm" href="/staff/owners/add-car" data-testid="add-car-link">Add a car for an owner</Link></PageHead>
    <p className="gm-links"><GuideMeLink flow="sales-move-owner" label="Guide me: move an owner forward" /></p>
    {board && <StageBoard b={board} base="/staff" refresh={refresh} />}
    {d && <><h2 className="d4">Prospective owners</h2><PipelineBoard d={d} refresh={refresh} /></>}
    {fn === 'sales' && <p className="small muted">Prospective owners you bring in are on <Link prefetch={false} className="link" href="/staff/my-sales#owners">My sales</Link>.</p>}
  </>);
}
