import { pageMeta } from '@/features/seo/meta';
import { requireStaff } from '@/server/door';
import { guideFor } from '@/server/guides';
import { GuideView } from '@/features/guides/GuideView';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Field guide', path: '/field/guide', noindex: true, description: 'Your jobs, handovers, returns and photos.' });

export default async function FieldGuide() {
  const { user } = await requireStaff('field', '/field/guide');
  return <GuideView g={await guideFor(user, 'field')} portal="field" pdfHref="/guide-pdf/field" />;
}
