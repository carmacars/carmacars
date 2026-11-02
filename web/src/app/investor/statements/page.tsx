import { redirect } from 'next/navigation';
import { movedTo } from '@/features/portal-nav/tabs';
import { INVESTOR_MOVED } from '@/features/investor/menu';

// r27 portals: this page is a tab of Documents now (features/investor/menu.ts); the query is kept.
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [to, tab] = INVESTOR_MOVED['/investor/statements']!;
  redirect(movedTo(to, tab, await searchParams));
}
