import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { PageHead } from '@/features/admin/ui';
import { DemoRenter } from '@/features/demo/DemoPortals';
import { demoViewer } from '@/features/demo/guard';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Demo renter portal', path: '/admin/demo/renter', noindex: true, description: 'The renter portal with made-up data, stage by stage.' });

// r50 hotfix 2: the demo renter portal (made-up data, nothing is saved or sent).
export default async function DemoRenterPage() {
  await demoViewer('/admin/demo/renter');
  return (<><PageHead kicker={<Link prefetch={false} className="link" href="/admin/demo">Demo portals</Link>} title="Demo renter portal" purpose="Pick a stage to see what the renter sees then." /><DemoRenter /></>);
}
