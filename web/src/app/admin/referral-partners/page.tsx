import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Card } from '@/features/admin/ui';
import { ReferralPartnersView } from '@/features/partners-section/ReferralPartners';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Referral partners', path: '/admin/referral-partners', noindex: true, description: 'Body shops and tow trucks that send us renters: partners, kickbacks, payments.' });

// Admin > People > Referral partners (migration 0164); the same page for Finance in the staff portal (1061). r50 (4511):
// the referrals we make ourselves (owners sent to an incorporation provider) are summed up here, kept in Settings.
export default async function ReferralPartners({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, user }, sp] = await Promise.all([page('/admin/referral-partners'), searchParams]);
  const inc = await read<{ settings: { provider_name: string; usable: boolean }; totals: { referred: number; incorporated: number } }>('incorporation_referral').catch(() => null);
  return (<>
    <ReferralPartnersView userId={user.id} base="/admin" sp={sp} read={read} />
    {inc && <Card title="Owners we refer: incorporation" testId="ir-summary">
      <p className="small">{inc.settings.usable ? `${inc.settings.provider_name}: ${inc.totals.referred} owner${inc.totals.referred === 1 ? '' : 's'} referred, ${inc.totals.incorporated} incorporated.` : `Off: paste your ${inc.settings.provider_name} affiliate link to show Incorporate now to owners who need a corporation.`}{' '}
        <Link prefetch={false} className="link" href="/admin/settings/incorporation-referral">Incorporation referral</Link></p>
    </Card>}
  </>);
}
