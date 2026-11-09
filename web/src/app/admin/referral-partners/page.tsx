import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { ReferralPartnersView } from '@/features/partners-section/ReferralPartners';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Referral partners', path: '/admin/referral-partners', noindex: true, description: 'Body shops and tow trucks that send us renters: partners, kickbacks, payments.' });

// Admin > People > Referral partners (migration 0164); the same page for Finance in the staff portal (1061).
export default async function ReferralPartners({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, user }, sp] = await Promise.all([page('/admin/referral-partners'), searchParams]);
  return <ReferralPartnersView userId={user.id} base="/admin" sp={sp} read={read} />;
}
