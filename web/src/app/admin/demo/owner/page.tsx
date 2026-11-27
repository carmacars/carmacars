import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { PageHead } from '@/features/admin/ui';
import { DemoOwner } from '@/features/demo/DemoPortals';
import { demoViewer } from '@/features/demo/guard';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Demo owner portal', path: '/admin/demo/owner', noindex: true, description: 'The owner portal with made-up data, stage by stage.' });

// r50 hotfix 2: the demo owner portal (made-up data, nothing is saved or sent).
export default async function DemoOwnerPage() {
  await demoViewer('/admin/demo/owner');
  return (<><PageHead kicker={<Link prefetch={false} className="link" href="/admin/demo">Demo portals</Link>} title="Demo owner portal" purpose="Pick a stage to see what the owner sees then." /><DemoOwner /></>);
}
