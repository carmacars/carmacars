import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { Scorecard, type Score } from '@/features/va/Scorecard';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'My scorecard', path: '/staff/scorecard', noindex: true, description: 'Your weekly measures.' });

// The assistant's own scorecard, read-only (05-va.md section 6).
export default async function MyScorecard() {
  const { read, fn } = await vaPage('/staff/scorecard');
  const s = await read<Score>('scorecard', { weeks: 6 });
  return (<><PageHead title="My scorecard" kicker={FN_LABEL[fn]} /><Scorecard s={s} /></>);
}
