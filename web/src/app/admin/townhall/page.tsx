import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { TownhallDeck } from '@/features/townhall/Townhall';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Townhall', path: '/admin/townhall', noindex: true, description: 'The weekly staff call and its deck.' });

// 1062: the weekly townhall, built every Sunday night from the live data.
export default async function AdminTownhall({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/townhall'), searchParams]);
  return (<><PageHead title="Townhall" purpose="The weekly staff call. The deck builds itself every Sunday night; add your notes to each slide." /><TownhallDeck userId={user.id} base="/admin" week={sp.week} /></>);
}
