import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';
import { ADMIN_MOVED } from '@/server/portal-access';

// r27: Owner statements is the Statements tab of Money > Owner money. A statement keeps its own page.
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [to, tab, tabs] = ADMIN_MOVED['/admin/statements']!;
  redirect(movedTo(to, tab, await searchParams, tabs));
}
