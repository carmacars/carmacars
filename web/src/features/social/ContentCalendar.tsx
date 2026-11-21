import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Badge } from '@/features/admin/ui';
import { photoUrl } from '@/lib/photo';
import { CHANNEL_WORDS, FORMAT_WORDS, mixOf, type CalChannel, type Format, type Learned, type Pillar } from './calendar';
import { Regenerate, WriteMonth } from './CalendarButtons';

// The content calendar (release 48, migration 3263; the owner, Nov 20: "an auto-generated CONTENT CALENDAR per business,
// approved by staff before anything goes live"). The month as a grid (from tablet width; a phone gets the list), then
// each post: its day, format and pillar, the opening line, the caption, hashtags, the best time on each channel and a
// music suggestion, with Approve, Edit, Reject and Regenerate. Only Approve sends a post to the queue; there the
// Facebook Page and Instagram are posted through Meta when it is connected, and a story, a carousel and every TikTok
// post wait with their download and checklist. A posted post takes its results, which lean next month's calendar.
// The same screen for an Admin and for Marketing staff (base: the page's own address).
export interface CalQueue { id: string; channel: CalChannel; status: string; scheduled_at: string; how: string | null; by_hand: boolean; post_url: string | null; error: string | null; media_path: string | null; media_kind: string;
  stats: { views: number | null; reach: number | null; likes: number | null; comments: number | null; shares: number | null; saves: number | null; source: string; score: number } | null }
export interface CalPost { id: string; slot_no: number; slot_date: string; weekday: string; format: Format; pillar: string; kind: string; channels: CalChannel[]; vehicle_id: string | null; car: string | null;
  hook: string | null; caption: string; hashtags: string[]; music: string | null; best_times: Partial<Record<CalChannel, string>>; link: string | null; photos: string[]; shot_list: string | null;
  status: 'draft' | 'approved' | 'posted' | 'rejected' | 'skipped'; edited: boolean; regenerated: number; reject_reason: string | null; approved_by: string | null; approved_at: string | null; has_video: boolean; queue: CalQueue[] }
export interface CalData { month: string; label: string; today: string; enabled: boolean; first_weekday: number; days: number; prev: string; next: string; generated_at: string | null;
  learned: Learned; learned_now: Learned; pillars: Pillar[]; meta: { connected: boolean; instagram: boolean; last_error: string | null };
  auto_reply: { instagram: boolean; messenger: boolean; per_sender_day: number; rule: string };
  counts: { all: number; draft: number; approved: number; posted: number; rejected: number }; posts: CalPost[];
  videos: Array<{ id: string; vehicle_id: string; car: string; path: string; mime: string; seconds: number }> }

const STATUS: Record<CalPost['status'], [string, string]> = { draft: ['submitted', 'To approve'], approved: ['published', 'Approved'], posted: ['closed', 'Posted'], rejected: ['draft', 'Rejected'], skipped: ['closed', 'Skipped'] };
const DOW = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const clock = (hhmm: string | undefined) => { if (!hhmm) return ''; const [h, m] = hhmm.split(':').map(Number) as [number, number]; return `${h % 12 === 0 ? 12 : h % 12}:${String(m).padStart(2, '0')} ${h < 12 ? 'am' : 'pm'}`; };
const dayWords = (d: string) => new Date(`${d}T12:00:00Z`).toLocaleDateString('en-CA', { weekday: 'long', month: 'long', day: 'numeric', timeZone: 'UTC' });
const at = (iso: string) => new Date(iso).toLocaleString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
const QSTATUS: Record<string, string> = { queued: 'Scheduled', due: 'Due now', posting: 'Posting', posted: 'Posted', failed: 'Failed', cancelled: 'Cancelled' };

function learnedLine(l: Learned, pillars: Pillar[]): string | null {
  if (!l || !(l.posts ?? 0)) return null;
  const pillar = pillars.find((p) => p.code === l.top_pillar)?.name;
  const times = Object.entries(l.times ?? {}).map(([ch, t]) => `${CHANNEL_WORDS[ch as CalChannel] ?? ch} around ${clock(t)}`);
  const parts = [pillar ? `${pillar} did best` : null, l.top_format ? `${FORMAT_WORDS[l.top_format as Format] ?? l.top_format}s did best` : null, times.length ? `best times: ${times.join(', ')}` : null].filter(Boolean);
  return parts.length ? `From the results of ${l.posts} posts: ${parts.join('; ')}. The next calendar leans on it.` : `Results of ${l.posts} posts so far. A pattern shows once a few more are in.`;
}

function PostCard({ p, d, queuePage, refresh }: { p: CalPost; d: CalData; queuePage: string; refresh: string[] }) {
  const pillar = d.pillars.find((x) => x.code === p.pillar)?.name ?? p.pillar;
  const [tone, word] = STATUS[p.status] ?? STATUS.draft;
  const videos = d.videos.filter((v) => !p.vehicle_id || v.vehicle_id === p.vehicle_id);
  const canApprove = p.status === 'draft' || p.status === 'rejected';
  const needsVideo = p.format === 'reel' && videos.length === 0;
  const sid = p.id.slice(0, 8);
  return (
    <li className="rw-post" id={`post-${p.slot_no}`} data-testid={`cal-post-${p.slot_no}`} data-status={p.status} data-format={p.format}>
      <div className="rw-post__media">{p.photos[0]
        // eslint-disable-next-line @next/next/no-img-element
        ? <img src={photoUrl(p.photos[0])} alt={p.car ? `${p.car}` : 'The post\'s photo'} loading="lazy" decoding="async" width={320} height={240} />
        : <span className="rw-post__nomedia">No photo yet</span>}</div>
      <div className="rw-post__body stack">
        <div className="rw-post__head">
          <p className="rw-post__when"><b>{dayWords(p.slot_date)}</b></p>
          <p className="rw-post__tags"><span className="badge badge--outline" data-testid={`cal-format-${p.slot_no}`}>{FORMAT_WORDS[p.format]}</span><span className="badge badge--grey">{pillar}</span><Badge s={tone}>{word}</Badge></p>
        </div>
        {p.hook && <p className="rw-post__hook">{p.hook}</p>}
        <p className="rw-post__caption" data-testid={`cal-caption-${p.slot_no}`}>{p.caption}</p>
        {p.hashtags.length > 0 && <p className="rw-post__hash">{p.hashtags.join(' ')}</p>}
        <dl className="rw-post__facts">
          <div><dt>Best times</dt><dd>{p.channels.map((ch) => `${CHANNEL_WORDS[ch]} ${clock(p.best_times[ch])}`).join(' · ')}</dd></div>
          {p.music && <div><dt>Music</dt><dd>{p.music}</dd></div>}
          {p.car && <div><dt>Car</dt><dd>{p.car}</dd></div>}
        </dl>
        {p.shot_list && <details className="rw-more"><summary>How to make it</summary><p className="small">{p.shot_list}</p>
          {p.format !== 'photo' && <p className="small muted">Instagram and TikTok do not let us attach their licensed music for you: pick the sound when you post, or use a royalty-free track in the video.</p>}</details>}
        {p.status === 'rejected' && p.reject_reason && <p className="small" data-testid={`cal-reason-${p.slot_no}`}><b>Rejected:</b> {p.reject_reason}</p>}
        {p.queue.length > 0 && (
          <ul className="rw-list" aria-label="Where it goes" data-testid={`cal-queue-${p.slot_no}`}>
            {p.queue.map((q) => (
              <li key={q.id} className="rw-list__row">
                <span className="rw-list__main"><b>{CHANNEL_WORDS[q.channel]}</b>
                  <small>{QSTATUS[q.status] ?? q.status}{q.status === 'posted' ? '' : `, ${at(q.scheduled_at)}`}{q.by_hand || !d.meta.connected ? ', posted by hand (download and checklist)' : ', through Meta'}{q.error ? `. ${q.error}` : ''}</small>
                  {q.stats && <small data-testid={`cal-stats-${sid}-${q.channel}`}>Results: {[q.stats.views != null ? `${q.stats.views} views` : '', q.stats.likes != null ? `${q.stats.likes} likes` : '', q.stats.comments != null ? `${q.stats.comments} comments` : '',
                    q.stats.shares != null ? `${q.stats.shares} shares` : '', q.stats.saves != null ? `${q.stats.saves} saves` : ''].filter(Boolean).join(', ')}{q.stats.source === 'api' ? ' (from Meta)' : ''}</small>}
                </span>
                <span className="rw-list__actions">
                  {q.post_url && <a className="link small" href={q.post_url} target="_blank" rel="noopener noreferrer">Open the post</a>}
                  {q.status === 'posted' && (q.how === 'hand' || !q.stats) && (
                    <Act ops action="social_stats_save" payload={{ id: q.id }} label={q.stats ? 'Update results' : 'Add results'} variant="quiet" refresh={refresh} done="Saved. Next month's calendar reads it." testId={`cal-stats-add-${sid}-${q.channel}`} title={`Results on ${CHANNEL_WORDS[q.channel]}`}
                      fields={[{ name: 'views', label: 'Views', type: 'number', min: 0, value: q.stats?.views ?? '' }, { name: 'likes', label: 'Likes', type: 'number', min: 0, value: q.stats?.likes ?? '' },
                        { name: 'comments', label: 'Comments', type: 'number', min: 0, value: q.stats?.comments ?? '' }, { name: 'shares', label: 'Shares', type: 'number', min: 0, value: q.stats?.shares ?? '' },
                        { name: 'saves', label: 'Saves', type: 'number', min: 0, value: q.stats?.saves ?? '' }]} />)}
                </span>
              </li>))}
          </ul>
        )}
        <div className="rw-post__actions">
          {canApprove && (needsVideo
            ? <p className="small" data-testid={`cal-needs-video-${p.slot_no}`}><b>A reel needs a short video.</b> Make one for {p.car ?? 'a car'} from its photos on <Link prefetch={false} className="link" href={queuePage}>the queue page (Make a short video)</Link>, then approve.</p>
            : <Act ops action="social_cal_decide" payload={{ id: p.id, action: 'approve' }} label="Approve" variant="primary" refresh={refresh} done="Approved. It is scheduled." testId={`cal-approve-${p.slot_no}`}
                title={`Approve: ${FORMAT_WORDS[p.format]} for ${dayWords(p.slot_date)}`} submitLabel="Approve and schedule"
                confirm={`It is scheduled for ${dayWords(p.slot_date)} and posts then. Take the approval back any time before.`}
                fields={[...(p.format === 'reel' ? [{ name: 'video', label: 'The short video', type: 'select' as const, required: true, value: videos[0]?.id ?? '',
                  options: videos.map((v) => [v.id, `${v.car}, ${Math.round(v.seconds)} s${v.mime === 'video/mp4' ? '' : ' (not MP4: no Instagram)'}`] as [string, string]) }] : []),
                  ...(p.format !== 'photo' ? [{ name: 'music', label: 'Music (picked when posting)', type: 'text' as const, value: p.music ?? '', wide: true, hint: 'A suggestion to follow when posting. The apps add their own licensed sounds; we cannot attach them for you.' }] : [])]} />)}
          {canApprove && <Act ops action="social_cal_save" payload={{ id: p.id }} label="Edit" refresh={refresh} done="Saved." testId={`cal-edit-${p.slot_no}`} title="Edit the post"
            fields={[{ name: 'hook', label: 'Opening line (on screen)', type: 'text', value: p.hook ?? '', wide: true }, { name: 'caption', label: 'Caption', type: 'textarea', required: true, value: p.caption, wide: true },
              { name: 'hashtags', label: 'Hashtags', type: 'text', value: p.hashtags.join(' '), wide: true }, { name: 'slot_date', label: 'Day', type: 'date', value: p.slot_date },
              { name: 'music', label: 'Music suggestion', type: 'text', value: p.music ?? '', wide: true }]} />}
          {canApprove && <Regenerate month={d.month} id={p.id} />}
          {p.status === 'draft' && <Act ops action="social_cal_decide" payload={{ id: p.id, action: 'reject' }} label="Reject" variant="quiet" refresh={refresh} done="Rejected. It will not be posted." testId={`cal-reject-${p.slot_no}`} title="Reject this post"
            fields={[{ name: 'reason', label: 'Why (it helps the next calendar)', type: 'text', required: true, wide: true }]} />}
          {p.status === 'rejected' && <Act ops action="social_cal_decide" payload={{ id: p.id, action: 'restore' }} label="Restore" variant="quiet" refresh={refresh} done="Back to waiting for approval." testId={`cal-restore-${p.slot_no}`} />}
          {p.status === 'approved' && !p.queue.some((q) => q.status === 'posted' || q.status === 'posting') && (
            <Act ops action="social_cal_decide" payload={{ id: p.id, action: 'unapprove' }} label="Take the approval back" variant="quiet" confirm="Take the approval back? Its scheduled posts are cancelled and it becomes a draft again." refresh={refresh} done="Back to a draft." testId={`cal-unapprove-${p.slot_no}`} />)}
          {p.status === 'approved' && p.approved_by && <span className="small muted">Approved by {p.approved_by}</span>}
        </div>
      </div>
    </li>
  );
}

export function ContentCalendar({ d, base, status }: { d: CalData; base: string; status?: string }) {
  const refresh = [base];
  const shown = status && status !== 'all' ? d.posts.filter((p) => p.status === status) : d.posts;
  const byDay = new Map<string, CalPost[]>();
  for (const p of d.posts) byDay.set(p.slot_date, [...(byDay.get(p.slot_date) ?? []), p]);
  const mix = mixOf(d.posts);
  const cells: Array<number | null> = [...Array.from({ length: d.first_weekday - 1 }, () => null), ...Array.from({ length: d.days }, (_, i) => i + 1)];
  while (cells.length % 7) cells.push(null);
  const learned = learnedLine(d.learned_now, d.pillars);
  const filters: Array<[string, string, number]> = [['all', 'All', d.counts.all], ['draft', 'To approve', d.counts.draft], ['approved', 'Approved', d.counts.approved], ['posted', 'Posted', d.counts.posted], ['rejected', 'Rejected', d.counts.rejected]];
  const queuePage = base.startsWith('/admin') ? '/admin/marketing/social' : '/staff/marketing';
  return (
    <div className="rw-cal stack-lg" data-testid="content-calendar" data-month={d.month}>
      <nav className="rw-cal__nav" aria-label="Months">
        <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}?month=${d.prev}`} data-testid="cal-prev">Previous</Link>
        <b className="rw-cal__month" data-testid="cal-month">{d.label}</b>
        <Link prefetch={false} className="btn btn--ghost btn--sm" href={`${base}?month=${d.next}`} data-testid="cal-next">Next</Link>
      </nav>

      <ul className="rw-cal__notes" data-testid="cal-notes">
        <li data-testid="cal-meta"><b>Publishing.</b> {d.meta.connected ? `Meta is connected: approved Facebook Page${d.meta.instagram ? ' and Instagram' : ''} photos and reels post by themselves at their time.` : 'Meta is not connected yet: approved posts wait in the queue with a download and a checklist, and you post them by hand.'} Stories, carousels and every TikTok post are always by hand.
          {' '}<Link prefetch={false} className="link" href={queuePage}>The queue</Link></li>
        <li data-testid="cal-autoreply"><b>Comments and messages.</b> {d.auto_reply.rule} Instagram: {d.auto_reply.instagram ? 'on' : 'off'}. Messenger: {d.auto_reply.messenger ? 'on' : 'off'}.</li>
        {learned && <li data-testid="cal-learned"><b>What worked.</b> {learned}</li>}
      </ul>

      {d.posts.length === 0 ? (
        <div className="pt-empty" data-testid="cal-empty">
          <p className="d4">No calendar for {d.label} yet.</p>
          <p className="muted">{d.enabled ? 'It is written by itself near the end of the month before. You can write it now.' : 'The content calendar is switched off in Program settings.'}</p>
          {d.enabled && d.month >= d.today.slice(0, 7) && <p><WriteMonth month={d.month} label="Write the calendar" /></p>}
        </div>
      ) : (<>
        <p className="small" data-testid="cal-mix">{d.posts.length} posts: {Object.entries(mix.formats).map(([f, n]) => `${n} ${(FORMAT_WORDS[f as Format] ?? f).toLowerCase()}${n === 1 ? '' : 's'}`).join(', ')}.
          {' '}Pillars: {Object.entries(mix.pillars).map(([c, n]) => `${d.pillars.find((x) => x.code === c)?.name ?? c} ${n}`).join(', ')}.</p>

        <div className="rw-grid7" role="table" aria-label={`${d.label}: the posts by day`} data-testid="cal-grid">
          <div role="row" className="rw-grid7__head">{DOW.map((x) => <span role="columnheader" key={x}>{x}</span>)}</div>
          {Array.from({ length: cells.length / 7 }, (_, w) => (
            <div role="row" className="rw-grid7__row" key={w}>
              {cells.slice(w * 7, w * 7 + 7).map((n, i) => {
                const day = n ? `${d.month}-${String(n).padStart(2, '0')}` : null;
                const posts = day ? byDay.get(day) ?? [] : [];
                return (
                  <div role="cell" key={i} className="rw-grid7__cell" data-out={!n || undefined} data-today={day === d.today || undefined}>
                    {n && <span className="rw-grid7__n">{n}</span>}
                    {posts.map((p) => <a key={p.id} className="rw-chip" href={`#post-${p.slot_no}`} data-status={p.status} title={`${FORMAT_WORDS[p.format]}: ${STATUS[p.status]?.[1] ?? p.status}`}>
                      <span className="rw-chip__dot" aria-hidden="true" /><span>{FORMAT_WORDS[p.format]}</span><span className="vh">, {STATUS[p.status]?.[1] ?? p.status}</span></a>)}
                  </div>);
              })}
            </div>))}
        </div>

        <p className="ad-filters" aria-label="Show">
          {filters.map(([k, l, n]) => <Link prefetch={false} key={k} href={`${base}?month=${d.month}${k === 'all' ? '' : `&status=${k}`}`} aria-current={(status ?? 'all') === k ? 'page' : undefined} data-testid={`cal-filter-${k}`}>{l} {n}</Link>)}
        </p>
        {shown.length === 0 ? <div className="pt-empty"><p className="d4">Nothing here.</p><p className="muted">No post of {d.label} is in this state.</p></div>
          : <ul className="rw-posts" data-testid="cal-posts">{shown.map((p) => <PostCard key={p.id} p={p} d={d} queuePage={queuePage} refresh={refresh} />)}</ul>}
        {d.enabled && d.month >= d.today.slice(0, 7) && <p><WriteMonth month={d.month} label="Write the days still empty" primary={false} /></p>}
      </>)}
    </div>
  );
}
