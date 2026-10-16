import { pageMeta } from '@/features/seo/meta';
import { requireStaff } from '@/server/door';
import { SignOne } from '@/features/manual/SignPages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Sign', path: '/va/sign', noindex: true, description: 'Read and sign a document.' });

export default async function VaSignOne({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { user } = await requireStaff('va', `/va/sign/${id}`);
  return <SignOne userId={user.id} base="/va/sign" id={id} />;
}
