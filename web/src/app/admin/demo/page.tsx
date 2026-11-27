import { pageMeta } from '@/features/seo/meta';
import { PageHead } from '@/features/admin/ui';
import { DemoIndex } from '@/features/demo/DemoIndex';
import { demoViewer } from '@/features/demo/guard';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Demo portals', path: '/admin/demo', noindex: true, description: 'A demo renter portal and a demo owner portal with made-up data.' });

// r50 hotfix 2: the demo renter and owner portals (made-up data, nothing is saved or sent).
export default async function DemoPage() {
  await demoViewer('/admin/demo');
  return (<><PageHead title="Demo portals" purpose="See each process as a renter or an owner sees it, with made-up data. Nothing is saved or sent." /><DemoIndex base={'/admin'} /></>);
}
