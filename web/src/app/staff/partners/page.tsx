import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PartnersView } from '@/features/partners-section/Partners';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Partners', path: '/staff/partners', noindex: true, description: 'Partner rental companies whose cars CarmaCars rents out on commission.' });

// 1061: Finance has the whole Partners section, as Admin does.
export default async function StaffPartners() {
  const { user } = await vaPage('/staff/partners', ['finance']);
  return <PartnersView userId={user.id} base="/staff" />;
}
