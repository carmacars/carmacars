import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { AdminCallDeck } from '@/features/admin-call/AdminCall';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Admin call', path: '/admin/admin-call', noindex: true, description: 'The weekly Admin call: the deck with its decisions, the call and the invite.' });

// r50 hotfix 2 (5150): the weekly Admin call, built from the live data before each call.
export default async function AdminCallPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ user }, sp] = await Promise.all([page('/admin/admin-call'), searchParams]);
  return (<><PageHead title="Admin call" purpose="The weekly call of the Admins: the week's deck, with Approve and Deny on every decision to take." /><AdminCallDeck userId={user.id} week={sp.week} /></>);
}
