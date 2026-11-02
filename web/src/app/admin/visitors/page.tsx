import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { liveMap } from '@/server/admin/live-map';
import type { Inbox, LiveData } from '@/features/live/staff';
import { liveWithoutContact } from '@/features/live/contact';
import { historyParams, type HistoryData } from '@/features/visitors/history';
import type { PhoneInboxData } from '@/features/phone/client';
import { VisitorsPage } from '@/features/visitors/VisitorsPage';
import { viewOf } from '@/features/visitors/tabs';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Visitors', path: '/admin/visitors', noindex: true, description: 'Who is on the site now, the chats and texts with them, and who came before.' });

const ID = /^[0-9a-f-]{36}$/;
// Today > Visitors (Release 26; r27 consolidation: Live chat is its Chat tab): Live now, Chat and History on one page
// (features/visitors/VisitorsPage.tsx). The old addresses (/admin/live, /admin/live/history, /admin/live-map without
// ?tv=1, /admin/chat) send here with their query kept. Admins only, as before; the map and Live now are drawn without
// any phone or email ("Show contact" asks for them).
export default async function Visitors({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [{ user, read }, sp] = await Promise.all([page('/admin/visitors'), searchParams]);
  const view = viewOf(sp.view);
  const id = typeof sp.id === 'string' && ID.test(sp.id) ? sp.id : undefined;
  const [map, live, hist, chat, phone, counts] = await Promise.all([
    view === 'chat' ? Promise.resolve(null) : liveMap(user.id, false).catch(() => null),
    view === 'live' ? read<LiveData>('live_visitors').then(liveWithoutContact) : Promise.resolve(null),
    view === 'history' ? read<HistoryData>('visitor_history', historyParams(sp)) : Promise.resolve(null),
    view === 'chat' && sp.inbox !== 'phone' ? read<Inbox>('chat_inbox') : Promise.resolve(null),
    view === 'chat' ? read<PhoneInboxData>('phone_inbox').catch(() => null) : Promise.resolve(null),
    read<{ waiting: number; hot?: number }>('chat_counts').catch(() => ({ waiting: 0, hot: 0 }))
  ]);
  return <VisitorsPage portal="admin" view={view} sp={sp} kicker="Today" openId={id}
    d={{ map, live, hist, chat, phone, hot: Number(counts.hot) || 0, waiting: Number(counts.waiting) || 0 }} />;
}
