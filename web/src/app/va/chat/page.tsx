import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { ChatInbox } from '@/features/live/ChatInbox';
import type { Inbox } from '@/features/live/staff';
import { PhoneInbox } from '@/features/phone/PhoneInbox';
import { InboxTabs } from '@/features/phone/InboxTabs';
import type { PhoneInboxData } from '@/features/phone/client';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Live chat', path: '/va/chat', noindex: true, description: 'Live chat with visitors, and texts and calls on the CarmaCars number.' });

const ID = /^[0-9a-f-]{36}$/;
// Live chat (migration 0060) and Texts and calls (0085): customer service and Sales.
export default async function VaChat({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read, fn }, sp] = await Promise.all([vaPage('/va/chat', ['cs', 'sales']), searchParams]);
  const openId = sp.id && ID.test(sp.id) ? sp.id : undefined;
  if (sp.view === 'phone') {
    const d = await read<PhoneInboxData>('phone_inbox');
    return (<><PageHead title="Texts and calls" kicker={FN_LABEL[fn]} /><InboxTabs base="/va/chat" view="phone" unread={d.unread} /><PhoneInbox initial={d} portal="va" openId={openId} fn={fn} /></>);
  }
  const [d, ph] = await Promise.all([read<Inbox>('chat_inbox'), read<PhoneInboxData>('phone_inbox').catch(() => null)]);
  return (<><PageHead title="Live chat" kicker={FN_LABEL[fn]} /><InboxTabs base="/va/chat" view="chat" unread={ph?.unread} /><ChatInbox initial={d} portal="va" openId={openId} /></>);
}
