import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { sessionAal } from '@/server/door';
import { RentalPage } from '@/features/insurance/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Insurance replacement', path: '/admin/insurance-replacements', noindex: true, description: 'One insurance replacement: the claim, the invoice and its versions, payments.' });

export default async function Page({ params, searchParams }: { params: Promise<{ number: string }>; searchParams: Promise<{ added?: string }> }) {
  const [{ number }, sp] = await Promise.all([params, searchParams]);
  const [{ user }, aal] = await Promise.all([page(`/admin/insurance-replacements/${encodeURIComponent(number)}`), sessionAal()]);
  return <RentalPage who={{ userId: user.id, aal }} base="/admin" number={decodeURIComponent(number)} added={sp.added === '1'} />;
}
