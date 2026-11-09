import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { ReferralPartnersView } from '@/features/partners-section/ReferralPartners';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Referral partners', path: '/staff/referral-partners', noindex: true, description: 'Body shops and tow trucks that send us renters: partners, kickbacks, payments.' });

// 1061: Finance has the referral partners as Admin does.
export default async function StaffReferralPartners({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, user }, sp] = await Promise.all([vaPage('/staff/referral-partners', ['finance']), searchParams]);
  return <ReferralPartnersView userId={user.id} base="/staff" sp={sp} read={read} />;
}
