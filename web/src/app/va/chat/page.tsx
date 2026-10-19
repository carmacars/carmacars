import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { ChatInbox } from '@/features/live/ChatInbox';
import type { Inbox } from '@/features/live/staff';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Live chat', path: '/va/chat', noindex: true, description: 'Live chat with visitors: the assistant first, then you.' });

// Live chat (migration 0060): customer service and Sales.
export default async function VaChat({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, fn }, sp] = await Promise.all([vaPage('/va/chat', ['cs', 'sales']), searchParams]);
  const d = await read<Inbox>('chat_inbox');
  return (<><PageHead title="Live chat" kicker={FN_LABEL[fn]} /><ChatInbox initial={d} portal="va" openId={sp.id && /^[0-9a-f-]{36}$/.test(sp.id) ? sp.id : undefined} /></>);
}
