import { notFound } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PartnerView } from '@/features/partners-section/Partner';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Partner', path: '/admin/partners', noindex: true, description: 'One partner rental company.' });

// One partner (migration 0046); the same page for Finance in the staff portal (1061).
export default async function Partner({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/.test(id)) notFound();
  const { user } = await page(`/admin/partners/${id}`);
  return <PartnerView userId={user.id} base="/admin" id={id} />;
}
