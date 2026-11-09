import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PartnerView } from '@/features/partners-section/Partner';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Partner', path: '/staff/partners', noindex: true, description: 'One partner rental company.' });

// 1061: one partner, for Finance.
export default async function StaffPartner({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { user } = await vaPage(`/staff/partners/${id}`, ['finance']);
  return <PartnerView userId={user.id} base="/staff" id={id} />;
}
