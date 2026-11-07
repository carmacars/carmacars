import { pageMeta } from '@/features/seo/meta';
import { RentersPage } from '@/features/renters-page/RentersPage';
import { staffCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Find a renter', path: '/staff/renters', noindex: true, description: 'Look up a renter.' });

// Find a renter (05-va.md section 4.4). r31: the same page as the Admin's Renters (features/renters-page).
export default async function Renters({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([staffCtx('/staff/renters', ['cs', 'finance', 'fleet']), searchParams]);
  return <RentersPage ctx={ctx} sp={sp} />;
}
