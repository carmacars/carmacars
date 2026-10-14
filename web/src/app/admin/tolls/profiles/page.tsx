import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { door } from '@/server/door';
import { PageHead } from '@/features/admin/ui';
import { ProfileList } from '@/features/tolls/Profiles';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Reading profiles', path: '/admin/tolls/profiles', noindex: true, description: 'How each issuer\'s notices are read.' });
export default async function Profiles() {
  const { user } = await page('/admin/tolls/profiles');
  const rows = await door<Parameters<typeof ProfileList>[0]['profiles']>(user.id, 'ops_read', 'toll_profiles');
  return (<>
    <PageHead kicker={<><Link prefetch={false} className="link" href="/admin/tolls">Tolls and tickets</Link> · <Link prefetch={false} className="link" href="/admin/tolls/read">Read a notice</Link></>} title="Reading profiles" />
    <p className="small muted">Each issuer&apos;s notices are read with the words below. The 407 ETR profile was built from the public layout of its statements: adjust it with the first real statement (paste its text under &quot;Try it&quot;).</p>
    <ProfileList profiles={rows} />
  </>);
}
