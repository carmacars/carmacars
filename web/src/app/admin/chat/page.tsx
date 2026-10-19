import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { ChatInbox } from '@/features/live/ChatInbox';
import type { Inbox } from '@/features/live/staff';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Live chat', path: '/admin/chat', noindex: true, description: 'Live chat with visitors: the assistant first, then a person.' });

// Bookings > Live chat (migration 0060).
export default async function Chat({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/chat'), searchParams]);
  const d = await read<Inbox>('chat_inbox');
  return (<><PageHead title="Live chat" kicker="Bookings" /><ChatInbox initial={d} portal="admin" openId={sp.id && /^[0-9a-f-]{36}$/.test(sp.id) ? sp.id : undefined} /></>);
}
