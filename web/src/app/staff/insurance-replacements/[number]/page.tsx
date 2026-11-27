import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { STAFF_ONLY } from '@/server/portal-access';
import { RentalPage } from '@/features/insurance/pages';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Insurance replacement', path: '/staff/insurance-replacements', noindex: true, description: 'One insurance replacement: the claim, the invoice and its versions, payments.' });

export default async function Page({ params, searchParams }: { params: Promise<{ number: string }>; searchParams: Promise<{ added?: string }> }) {
  const [{ number }, sp] = await Promise.all([params, searchParams]);
  const { user, aal } = await vaPage(`/staff/insurance-replacements/${encodeURIComponent(number)}`, STAFF_ONLY.insurance);
  return <RentalPage who={{ userId: user.id, aal }} base="/staff" number={decodeURIComponent(number)} added={sp.added === '1'} />;
}
