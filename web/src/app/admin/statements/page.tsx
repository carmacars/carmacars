import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';

// r27: Owner statements is the Statements tab of Money > Owner money. A statement keeps its own page.
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  redirect(movedTo('/admin/owner-money', 'statements', await searchParams));
}
