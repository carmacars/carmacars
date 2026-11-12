import { Badge, Card, Table, t } from '@/features/admin/ui';

// Admin > Marketing > Email campaigns (migration 2490), and Sales > Marketing > Email campaigns read only: who is in the
// marketing audience (everyone who gave us their email on the site), what is waiting, queued and sent, and who unsubscribed.
export type Campaign = { id: string; kind: 'weekly' | 'new_vehicle'; title: string; created_at: string; status: string;
  audience: number; waiting: number; queued: number; sent: number; skipped: number };
export type MarketingEmailsData = {
  can_edit: boolean; settings: Record<string, unknown>; daily_max: number; day_cap: number; hours: string;
  audience: number; contacts: number; by_source: Record<string, number>; unsubscribed: number; unsubscribed_30d: number; bounced: number;
  waiting: number; queued: number; sent_today: number; sent_7d: number; sent_30d: number;
  by_code: Array<{ code: string; subject: string; sent_30d: number }>; campaigns: Campaign[];
};

// the Program settings this page edits (Admin only)
export const MARKETING_EMAIL_KEYS = ['marketing_everyone_enabled', 'marketing_weekly_enabled', 'marketing_weekly_dow', 'marketing_weekly_hour', 'marketing_weekly_cars',
  'marketing_new_vehicle_enabled', 'marketing_auto_volume', 'marketing_transactional_reserve', 'notify_marketing_daily_max'];

const SOURCE: Array<[string, string]> = [['renter', 'Renters'], ['account', 'Accounts'], ['lead', 'Leads'], ['unfinished_form', 'Forms left unfinished']];
const n = (v: number) => v.toLocaleString('en-CA');

export function MarketingEmailsView({ d }: { d: MarketingEmailsData }) {
  return (<>
    <Card title="Audience and sending" testId="mkt-email-stats">
      <div className="ad-tiles">
        <div className="ad-tile"><span className="ad-tile__k">Audience</span><b className="ad-tile__v" data-testid="mkt-audience">{n(d.audience)}</b><span className="ad-tile__s">of {n(d.contacts)} addresses may be emailed</span></div>
        <div className="ad-tile"><span className="ad-tile__k">Waiting</span><b className="ad-tile__v" data-testid="mkt-waiting">{n(d.waiting)}</b><span className="ad-tile__s">campaign emails for the next days</span></div>
        <div className="ad-tile"><span className="ad-tile__k">Queued</span><b className="ad-tile__v" data-testid="mkt-queued">{n(d.queued)}</b><span className="ad-tile__s">marketing emails in the email queue</span></div>
        <div className="ad-tile"><span className="ad-tile__k">Sent</span><b className="ad-tile__v" data-testid="mkt-sent">{n(d.sent_7d)}</b><span className="ad-tile__s">last 7 days ({n(d.sent_today)} today, {n(d.sent_30d)} in 30 days)</span></div>
        <div className="ad-tile"><span className="ad-tile__k">Unsubscribed</span><b className="ad-tile__v" data-testid="mkt-unsubscribed">{n(d.unsubscribed)}</b><span className="ad-tile__s">{n(d.unsubscribed_30d)} in the last 30 days; {n(d.bounced)} bounced or complained</span></div>
      </div>
      <p className="small">Today marketing may send up to <b className="num" data-testid="mkt-daily-max">{n(d.daily_max)}</b> emails of the day&apos;s free capacity of {n(d.day_cap)}, between {d.hours} (Toronto time). Booking, payment and sign-in emails always go first; what does not fit waits for the next day. Nothing is ever sent on a paid plan.</p>
      <p className="small muted">Where the addresses came from: {SOURCE.map(([k, l]) => `${l} ${n(d.by_source[k] ?? 0)}`).join(', ')}. An address counts once. Consent basis: given on carmacars.ca. Anyone who unsubscribes is never emailed again; the link is in every marketing email and takes effect at once.</p>
    </Card>
    <Card title="Campaigns" testId="mkt-campaigns">
      <Table<Campaign> rows={d.campaigns} rowKey={(c) => c.id} empty="No campaign yet. The weekly email starts on its day; a new car's email starts when its listing goes live." cols={[
        { key: 'title', label: 'Campaign', render: (c) => <span>{c.title}<br /><span className="xs muted">{t(c.created_at)}</span></span> },
        { key: 'status', label: 'Status', render: (c) => <Badge s={c.status === 'sending' ? 'draft' : c.status === 'done' ? 'published' : 'closed'}>{c.status === 'sending' ? 'Sending' : c.status === 'done' ? 'Done' : 'Stopped'}</Badge> },
        { key: 'audience', label: 'People', render: (c) => <span className="num">{n(c.audience)}</span> },
        { key: 'sent', label: 'Sent', render: (c) => <span className="num">{n(c.sent)}</span> },
        { key: 'queued', label: 'Queued', render: (c) => <span className="num">{n(c.queued)}</span> },
        { key: 'waiting', label: 'Waiting', render: (c) => <span className="num">{n(c.waiting)}</span> },
        { key: 'skipped', label: 'Not sent', render: (c) => <span className="num">{n(c.skipped)}</span> }]} />
    </Card>
    <Card title="Marketing emails sent, last 30 days" testId="mkt-by-code">
      <Table<{ code: string; subject: string; sent_30d: number }> rows={d.by_code} rowKey={(r) => r.code} empty="None sent yet." cols={[
        { key: 'subject', label: 'Email', render: (r) => <span>{r.subject}<br /><span className="xs muted">{r.code}</span></span> },
        { key: 'sent_30d', label: 'Sent', render: (r) => <span className="num">{n(r.sent_30d)}</span> }]} />
    </Card>
  </>);
}
