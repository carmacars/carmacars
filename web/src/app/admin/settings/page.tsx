import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Card, PageHead } from '@/features/admin/ui';
import { SECTIONS } from './sections';
import { walletReady } from '@/server/wallet';
import { SettingsIndex } from '@/features/admin/settings-index/SettingsIndex';
import { settingsSections } from '@/features/admin/settings-index/groups';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Settings', path: '/admin/settings', noindex: true, description: 'Everything the owner changes without a developer.' });

export default async function Settings() {
  const { read } = await page('/admin/settings');
  const s = await read<{ problems: Array<{ message: string; href?: string | null }> }>('settings');
  // setup that needs a key only the owner's accounts can give (Release 22): listed until it is done
  if (!walletReady()) s.problems.push({ message: 'Add to Apple Wallet is hidden until CarmaCars has an Apple Pass Type ID certificate. In the Apple Developer account (Certificates, Identifiers & Profiles), create a Pass Type ID (pass.ca.carmacars.booking) and its certificate, then add deploy_wallet_pass_cert, deploy_wallet_pass_key, deploy_wallet_wwdr_cert, deploy_wallet_pass_type_id and deploy_wallet_team_id to the vault of the live database (the company server); the next deploy passes them to the Worker and the button then shows on every confirmed booking.', href: null });
  return (
    <>
      <PageHead title="Settings" kicker="Changes reach the public site at once" purpose="Everything you can change without a developer, in six sections. Type in the box to find one." />
      {s.problems.length > 0 && <Card title="Setup checklist" tone="warn"><ul className="small">{s.problems.map((p) => <li key={p.message}>{p.message}{p.href && <> <Link prefetch={false} className="link" href={p.href}>Open</Link></>}</li>)}</ul><Link prefetch={false} className="link small" href="/admin/settings/site">Open site settings</Link></Card>}
      {/* r27: the settings pages in six sections with anchors and a search (the menu now has one Settings link) */}
      <SettingsIndex sections={settingsSections(SECTIONS)} />
    </>
  );
}
