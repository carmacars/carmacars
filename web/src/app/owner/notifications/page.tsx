import { redirect } from 'next/navigation';
import { movedTo } from '@/features/portal-nav/tabs';
import { OWNER_MOVED } from '@/features/owner/menu';

// r27 portals: this page is a tab of a merged page now (features/owner/menu.ts); the query is kept.
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [to, tab] = OWNER_MOVED['/owner/notifications']!;
  redirect(movedTo(to, tab, await searchParams));
}
