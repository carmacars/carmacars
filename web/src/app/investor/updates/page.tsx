import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { currentUser } from '@/server/portal/data';
import { rolesOf } from '@/server/door';
import { UpdatesView } from '@/features/investor/UpdatesView';
import data from '@/features/investor/updates-data.json';
import type { Update } from '@/features/investor/updates';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Updates', path: '/investor/updates', noindex: true, description: 'Every release of the CarmaCars platform and what it added.' });

// Updates (release 29): every release, newest first, with what it added by area (features/investor/updates.ts; the data
// is built from docs/releases by scripts/gen-release-notes.mjs). For investors, and for Admins previewing the investor
// portal. Static text written for investors: nothing is read from the database.
export default async function InvestorUpdates() {
  const user = await currentUser();
  if (!user) redirect('/sign-in?next=/investor/updates');
  const roles = await rolesOf(user.id);
  if (!roles.investor && !roles.admin) redirect('/investor/no-access');
  return <UpdatesView updates={data as Update[]} preview={!roles.investor} />;
}
