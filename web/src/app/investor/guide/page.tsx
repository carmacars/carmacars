import { pageMeta } from '@/features/seo/meta';
import { requireInvestor } from '@/server/door';
import { guideFor } from '@/server/guides';
import { GuideView } from '@/features/guides/GuideView';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Investor guide', path: '/investor/guide', noindex: true, description: 'Your investments, statements and requests.' });

export default async function InvestorGuide() {
  const { user } = await requireInvestor('/investor/guide');
  return <GuideView g={await guideFor(user, 'investor')} portal="investor" pdfHref="/guide-pdf/investor" />;
}
