import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PartnersView } from '@/features/partners-section/Partners';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Partners', path: '/admin/partners', noindex: true, description: 'Partner rental companies whose cars CarmaCars rents out on commission.' });

// Admin > Partners (migration 0046); the same page for Finance in the staff portal (1061).
export default async function Partners() {
  const { user } = await page('/admin/partners');
  return <PartnersView userId={user.id} base="/admin" />;
}
