import { door } from '@/server/door';
import { siteUrl } from '@/lib/site';
import { feedUrl, SCOPE_WORDS, type FeedState } from './links';
import { ShiftFeedControls } from './ShiftFeedControls';

// r50 (5050): "Add shifts to Google Calendar". An Admin and Fleet get every field shift, a field staff member their own,
// by a private link the calendar subscribes to (no email). Nothing shows for a person who has no feed.
export async function ShiftFeedCard({ userId, call, className = 'pt-card stack' }: { userId: string; call: 'admin_read' | 'ops_read' | 'field_read'; className?: string }) {
  const s = await door<FeedState>(userId, call, 'shift_feed', {}).catch(() => null);
  if (!s || s.scopes.length === 0) return null;
  const site = siteUrl();
  return (<>
    {s.feeds.map((f) => (
      <section key={f.scope} className={className} aria-labelledby={`shift-feed-h-${f.scope}`} data-testid={`shift-feed-${f.scope}`}>
        <h2 className="d4" id={`shift-feed-h-${f.scope}`}>{SCOPE_WORDS[f.scope].title}</h2>
        <p className="small">{SCOPE_WORDS[f.scope].lead} New and changed shifts arrive by themselves, with no email.</p>
        <ShiftFeedControls scope={f.scope} url={f.token ? feedUrl(site, f.token) : null} />
        <p className="small muted">Google refreshes a subscribed calendar on its own schedule, every few hours, so a change can take that long to show.</p>
      </section>
    ))}
  </>);
}
