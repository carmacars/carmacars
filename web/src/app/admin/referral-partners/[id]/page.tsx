import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { ReferralPartnerView } from '@/features/partners-section/ReferralPartner';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Referral partner', path: '/admin/referral-partners', noindex: true, description: 'One referral partner: kickbacks and payments.' });

// One referral partner (migration 0164); the same page for Finance in the staff portal (1061).
export default async function ReferralPartner({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { read } = await page(`/admin/referral-partners/${id}`);
  return <ReferralPartnerView base="/admin" id={id} read={read} />;
}
