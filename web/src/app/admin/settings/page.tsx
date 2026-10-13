import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Card, PageHead } from '@/features/admin/ui';
import { SECTIONS } from './sections';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Settings', path: '/admin/settings', noindex: true, description: 'Everything the owner changes without a developer.' });

export default async function Settings() {
  const { read } = await page('/admin/settings');
  const s = await read<{ problems: Array<{ message: string }> }>('settings');
  return (
    <>
      <PageHead title="Settings" kicker="Changes reach the public site at once" />
      {s.problems.length > 0 && <Card title="Site setup" tone="warn"><ul className="small">{s.problems.map((p) => <li key={p.message}>{p.message}</li>)}</ul><Link className="link small" href="/admin/settings/site">Open site settings</Link></Card>}
      <div className="ad-cols ad-cols--3">{SECTIONS.map(([k, title, about]) => <Link key={k} className="ad-tile" href={`/admin/settings/${k}`}><span className="ad-tile__k">{title}</span><span className="small">{about}</span></Link>)}</div>
    </>
  );
}
