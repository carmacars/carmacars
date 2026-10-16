import { pageMeta } from '@/features/seo/meta';
import { requireStaff } from '@/server/door';
import { guideFor } from '@/server/guides';
import { GuideView } from '@/features/guides/GuideView';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'VA guide', path: '/va/guide', noindex: true, description: 'Your queue, your screens and how to work each task.' });

export default async function VaGuide() {
  const { user } = await requireStaff('va', '/va/guide');
  return <GuideView g={await guideFor(user, 'va')} portal="va" pdfHref="/guide-pdf/va" />;
}
