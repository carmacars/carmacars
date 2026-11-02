import Link from '@/components/Link';
import { PageHead } from '@/features/admin/ui';
import { LiveMap } from '@/features/live-map/LiveMap';
import type { MapView } from '@/features/live-map/model';
import { LiveVisitors } from '@/features/live/LiveVisitors';
import type { Inbox, LiveData } from '@/features/live/staff';
import { ChatInbox } from '@/features/live/ChatInbox';
import { PhoneInbox } from '@/features/phone/PhoneInbox';
import { InboxTabs } from '@/features/phone/InboxTabs';
import type { PhoneInboxData } from '@/features/phone/client';
import { HistoryList } from './HistoryList';
import type { HistoryData } from './history';
import { VIEWS, viewHref, viewLabel, visitorsBase, type VisitorsPortal, type VisitorsView } from './tabs';
import './visitors.css';

export interface VisitorsData {
  map: MapView | null; live: LiveData | null; hist: HistoryData | null;
  chat: Inbox | null; phone: PhoneInboxData | null;
  /** the badges of the tabs: hot visitors on Live now, chats waiting (and unread texts) on Chat */
  hot: number; waiting: number;
}

// One Visitors page for Admin and staff (r27 consolidation; the owner on November 1 and 2, 2026: Live visitors, Visitor
// history and Live map in one page, then Live chat in it too). The tabs on top so they never move: Live now (the map and
// who is on the site), Chat (live chat, with Texts and calls) and History (the map and past visits). Drawn without any phone
// or email: the browser asks for them only when "Show contact" is on. Staff (customer service and Sales) get the same
// page with their links; the database scopes what they read.
export function VisitorsPage({ portal, view, sp, d, kicker, openId }: { portal: VisitorsPortal; view: VisitorsView; sp: Record<string, string | string[] | undefined>;
  d: VisitorsData; kicker: string; openId?: string }) {
  const at = new Date().getTime();
  const lv = portal === 'admin' ? 'admin' : 'va';
  const inbox = sp.inbox === 'phone' ? 'phone' : 'chat';
  const badge = (v: VisitorsView) => (v === 'live' ? d.hot : v === 'chat' ? d.waiting + (d.phone?.unread ?? 0) : 0);
  return (
    <>
      <PageHead title="Visitors" kicker={kicker} purpose="Who is on the site now, the chats and texts with them, and who came before. Press a lead for its card." />
      <nav className="vs-tabs vs-tabs--top" aria-label="Visitors" data-testid="vs-tabs">
        {VIEWS.map((v) => {
          const n = badge(v);
          return (
            <Link prefetch={false} key={v} href={viewHref(portal, v)} className={`vs-tab${view === v ? ' is-on' : ''}`} aria-current={view === v ? 'page' : undefined} data-testid={`vs-tab-${v}`}>
              {viewLabel(v)}{n ? <span className="pt__count" aria-label={`${n} waiting`}>{n}</span> : null}
            </Link>);
        })}
      </nav>
      {view === 'chat' ? (
        <section className="vs-chat" aria-label="Chat" data-testid="visitors-chat">
          <InboxTabs base={viewHref(portal, 'chat')} view={inbox} unread={d.phone?.unread} />
          {inbox === 'phone'
            ? (d.phone ? <PhoneInbox initial={d.phone} portal={lv} openId={openId} /> : <p className="vs-empty">Texts and calls could not be read. Reload the page.</p>)
            : (d.chat ? <ChatInbox initial={d.chat} portal={lv} openId={openId} /> : <p className="vs-empty">The chats could not be read. Reload the page.</p>)}
        </section>
      ) : (
        <div className="vs" data-testid="visitors">
          <LiveMap initial={d.map} tv={false} at={at} embedded portal={portal} />
          <section className="vs-panel" aria-label={viewLabel(view)}>
            {portal === 'admin' && view === 'history' && <div className="vs-panel__links small"><Link prefetch={false} className="link" href="/admin/live/signals">Signal settings</Link></div>}
            {view === 'live' && d.live ? <LiveVisitors initial={d.live} portal={lv} inVisitors />
              : view === 'history' && d.hist ? <HistoryList d={d.hist} sp={sp} now={at} base={visitorsBase(portal)} />
              : <p className="vs-empty">This list could not be read. Reload the page.</p>}
          </section>
        </div>
      )}
    </>
  );
}
