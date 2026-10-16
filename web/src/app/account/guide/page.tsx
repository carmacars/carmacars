import { pageMeta } from '@/features/seo/meta';
import { requireUser } from '@/server/portal/data';
import { guideFor } from '@/server/guides';
import { GuideView } from '@/features/guides/GuideView';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Renter guide', path: '/account/guide', noindex: true, description: 'How to book, sign, pay and manage your trips.' });

export default async function RenterGuide() {
  const user = await requireUser('/account/guide');
  return <GuideView g={await guideFor(user, 'renter')} portal="renter" pdfHref="/guide-pdf/renter" />;
}
