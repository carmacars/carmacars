import { pageMeta } from '@/features/seo/meta';
import { requireInvestor } from '@/server/door';
import { SignList } from '@/features/manual/SignPages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Documents to sign', path: '/investor/sign', noindex: true, description: 'Your investment agreement, signed online.' });

export default async function InvestorSign() {
  const { user } = await requireInvestor('/investor/sign');
  return <SignList userId={user.id} base="/investor/sign" />;
}
