import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Card, PageHead } from '@/features/admin/ui';
import { SECTIONS } from './sections';
import { walletReady } from '@/server/wallet';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Settings', path: '/admin/settings', noindex: true, description: 'Everything the owner changes without a developer.' });

export default async function Settings() {
  const { read } = await page('/admin/settings');
  const s = await read<{ problems: Array<{ message: string; href?: string | null }> }>('settings');
  // setup that needs a key only the owner's accounts can give (Release 22): listed until it is done
  if (!walletReady()) s.problems.push({ message: 'Add to Apple Wallet is hidden until CarmaCars has an Apple Pass Type ID certificate. In the Apple Developer account (Certificates, Identifiers & Profiles), create a Pass Type ID (pass.ca.carmacars.booking) and its certificate, then add WALLET_PASS_CERT, WALLET_PASS_KEY, WALLET_WWDR_CERT, WALLET_PASS_TYPE_ID and WALLET_TEAM_ID to the Worker\'s secrets. The button then shows on every confirmed booking.', href: null });
  return (
    <>
      <PageHead title="Settings" kicker="Changes reach the public site at once" purpose="Everything you can change without a developer. Press Ctrl+K and type a name to jump straight to one." />
      {s.problems.length > 0 && <Card title="Setup checklist" tone="warn"><ul className="small">{s.problems.map((p) => <li key={p.message}>{p.message}{p.href && <> <Link prefetch={false} className="link" href={p.href}>Open</Link></>}</li>)}</ul><Link prefetch={false} className="link small" href="/admin/settings/site">Open site settings</Link></Card>}
      {/* every settings page as a card: its name and what is in it (admin portal design, October 25, 2026) */}
      <ul className="ad-settings" aria-label="Settings pages">{SECTIONS.map(([k, title, about]) => (
        <li key={k}><Link prefetch={false} href={`/admin/settings/${k}`}><span className="ad-settings__mark" aria-hidden="true">{title.charAt(0)}</span><b>{title}</b><span className="small">{about}</span></Link></li>))}</ul>
    </>
  );
}
