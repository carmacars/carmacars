import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { ReferralPartnerView } from '@/features/partners-section/ReferralPartner';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Referral partner', path: '/staff/referral-partners', noindex: true, description: 'One referral partner: kickbacks and payments.' });

// 1061: one referral partner, for Finance.
export default async function StaffReferralPartner({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { read } = await vaPage(`/staff/referral-partners/${id}`, ['finance']);
  return <ReferralPartnerView base="/staff" id={id} read={read} />;
}
