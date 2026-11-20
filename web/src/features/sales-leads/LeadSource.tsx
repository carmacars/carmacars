import { Card, Kv } from '@/features/admin/ui';
import { trafficBadge, trafficRows, type LeadTraffic } from './model';

// Where a lead came from (release 48, migration 3230), the same for an Admin and staff: the channel (ChatGPT, Google
// search, Google Ads ...), the search terms when the visit carried them, the first page opened and the referring page.
// Google does not send the words searched, so a Google visit lists the landing page's top Search Console queries instead.

/** The badge of a lead card. */
export function SourceBadge({ t }: { t: LeadTraffic | null | undefined }) {
  if (!t) return null;
  return <span className={`sl-src sl-src--${t.group}`} data-testid="lead-traffic" data-channel={t.channel} title={t.landing ? `First page: ${t.landing}` : undefined}>{trafficBadge(t)}</span>;
}

/** The card of the lead page. */
export function SourceCard({ t }: { t: LeadTraffic | null | undefined }) {
  return (
    <Card title="Where they came from" testId="lead-traffic-card">
      {t ? <>
        <Kv rows={trafficRows(t)} />
        {t.queries.length > 0 && <div className="small" data-testid="lead-queries">
          <p className="muted" style={{ margin: 'var(--s-2) 0 var(--s-1)' }}>Google does not pass the words searched. The top Google searches that bring people to {t.landing ?? 'that page'} (Search Console):</p>
          <ul className="sl-queries">{t.queries.map((q) => <li key={q.query}><b>{q.query}</b> <span className="muted num">{q.clicks} click{q.clicks === 1 ? '' : 's'}, {q.impressions} shown</span></li>)}</ul>
        </div>}
      </> : <p className="small muted">Not recorded for this lead. The source is kept for forms and requests sent from the website since release 48; calls, chats and leads typed by staff have none.</p>}
    </Card>
  );
}
