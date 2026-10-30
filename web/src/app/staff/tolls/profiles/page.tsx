import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { ProfileList } from '@/features/tolls/Profiles';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Reading profiles', path: '/staff/tolls/profiles', noindex: true, description: 'How each issuer\'s notices are read.' });
export default async function VaProfiles() {
  const { user, aal } = await vaPage('/staff/tolls/profiles', ['finance']);
  const rows = await door<Parameters<typeof ProfileList>[0]['profiles']>(user.id, 'ops_read', 'toll_profiles', {}, aal);
  return (<>
    <PageHead kicker={<><Link prefetch={false} className="link" href="/staff/tolls">Tolls and tickets</Link> · <Link prefetch={false} className="link" href="/staff/tolls/read">Read a notice</Link></>} title="Reading profiles" />
    <ProfileList profiles={rows} />
  </>);
}
