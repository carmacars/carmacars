import { pageMeta } from '@/features/seo/meta';
import { RentersPage } from '@/features/renters-page/RentersPage';
import { adminCtx } from '@/features/shared-pages/context';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Renters', path: '/admin/renters', noindex: true, description: 'Every renter, and the leads who are not renters yet.' });

// People > Renters. r31: the same page as staff's Find a renter (features/renters-page).
export default async function Renters({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([adminCtx('/admin/renters'), searchParams]);
  return <RentersPage ctx={ctx} sp={sp} />;
}
