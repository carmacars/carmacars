import { redirect } from 'next/navigation';
import { requireAdmin } from '@/server/admin/data';

export const dynamic = 'force-dynamic';
export default async function AdminHome() {
  await requireAdmin('/admin');
  redirect('/admin/owners');
}
