import { pageMeta } from '@/features/seo/meta';
import { requireOwner } from '@/server/owner/data';
import { guideFor } from '@/server/guides';
import { GuideView } from '@/features/guides/GuideView';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner guide', path: '/owner/guide', noindex: true, description: 'Your cars, your money and your paperwork, step by step.' });

export default async function OwnerGuide() {
  const { user } = await requireOwner('/owner/guide');
  return <GuideView g={await guideFor(user, 'owner')} portal="owner" pdfHref="/guide-pdf/owner" />;
}
