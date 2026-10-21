import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { PageHead } from '@/features/admin/ui';
import { ChatInbox } from '@/features/live/ChatInbox';
import type { Inbox } from '@/features/live/staff';
import { PhoneInbox } from '@/features/phone/PhoneInbox';
import { InboxTabs } from '@/features/phone/InboxTabs';
import type { PhoneInboxData } from '@/features/phone/client';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Live chat', path: '/admin/chat', noindex: true, description: 'Live chat with visitors, and texts and calls on the CarmaCars number.' });

const ID = /^[0-9a-f-]{36}$/;
// Bookings > Live chat (migration 0060), with Texts and calls (0085).
export default async function Chat({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/chat'), searchParams]);
  const openId = sp.id && ID.test(sp.id) ? sp.id : undefined;
  if (sp.view === 'phone') {
    const d = await read<PhoneInboxData>('phone_inbox');
    return (<><PageHead title="Texts and calls" kicker="Bookings" /><InboxTabs base="/admin/chat" view="phone" unread={d.unread} /><PhoneInbox initial={d} portal="admin" openId={openId} /></>);
  }
  const [d, ph] = await Promise.all([read<Inbox>('chat_inbox'), read<PhoneInboxData>('phone_inbox').catch(() => null)]);
  return (<><PageHead title="Live chat" kicker="Bookings" /><InboxTabs base="/admin/chat" view="chat" unread={ph?.unread} /><ChatInbox initial={d} portal="admin" openId={openId} /></>);
}
