import { pageMeta } from '@/features/seo/meta';
import { requireInvestor } from '@/server/door';
import { SignOne } from '@/features/manual/SignPages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign', path: '/investor/sign', noindex: true, description: 'Read and sign a document.' });

export default async function InvestorSignOne({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { user } = await requireInvestor(`/investor/sign/${id}`);
  return <SignOne userId={user.id} base="/investor/sign" id={id} />;
}
