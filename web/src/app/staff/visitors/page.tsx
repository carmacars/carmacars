import { pageMeta } from '@/features/seo/meta';
import { vaPage, FN_LABEL } from '@/server/va';
import type { Inbox, LiveData } from '@/features/live/staff';
import { liveWithoutContact } from '@/features/live/contact';
import { historyParams, type HistoryData } from '@/features/visitors/history';
import type { PhoneInboxData } from '@/features/phone/client';
import { toView, type RawMap } from '@/features/live-map/model';
import { VisitorsPage } from '@/features/visitors/VisitorsPage';
import { viewOf } from '@/features/visitors/tabs';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Visitors', path: '/staff/visitors', noindex: true, description: 'Who is on the site now, the chats and texts with them, and who came before.' });

const ID = /^[0-9a-f-]{36}$/;
// Visitors for customer service and Sales (r27 consolidation, the owner: every Admin upgrade reaches each staff role's
// portal): Admin's page (the live map with its clusters, Live now, Chat with Texts and calls, History, the roles, Show
// contact) in place of Live visitors and Live chat. The database scopes the reads to the function (migration 0500: the map
// without the fleet layer and the money); the old /staff/live and /staff/chat addresses redirect here.
export default async function StaffVisitors({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [{ read, fn }, sp] = await Promise.all([vaPage('/staff/visitors', ['cs', 'sales']), searchParams]);
  const view = viewOf(sp.view);
  const id = typeof sp.id === 'string' && ID.test(sp.id) ? sp.id : undefined;
  // r47: every read has a fallback (the page says which part did not load), as r46 did for Game leads: one busy read
  // failed the whole page (React #441)
  const [map, live, hist, chat, phone, counts] = await Promise.all([
    view === 'chat' ? Promise.resolve(null) : read<RawMap>('live_map').then((r) => toView(r, false)).catch(() => null),
    view === 'live' ? read<LiveData>('live_visitors').then(liveWithoutContact).catch(() => null) : Promise.resolve(null),
    view === 'history' ? read<HistoryData>('visitor_history', historyParams(sp)).catch(() => null) : Promise.resolve(null),
    view === 'chat' && sp.inbox !== 'phone' ? read<Inbox>('chat_inbox').catch(() => null) : Promise.resolve(null),
    view === 'chat' ? read<PhoneInboxData>('phone_inbox').catch(() => null) : Promise.resolve(null),
    read<{ waiting: number; hot?: number }>('chat_counts').catch(() => ({ waiting: 0, hot: 0 }))
  ]);
  return <VisitorsPage portal="staff" view={view} sp={sp} kicker={FN_LABEL[fn]} openId={id}
    d={{ map, live, hist, chat, phone, hot: Number(counts.hot) || 0, waiting: Number(counts.waiting) || 0 }} />;
}
