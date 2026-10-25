import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, Card, PageHead } from '@/features/admin/ui';
import { withUtm } from '@/features/ads/channels';
import { CopyText } from '@/features/ads/CopyText';
import { MarketingTabs } from '@/features/ads/MarketingTabs';
import { KIND_WORDS, addDays, captionFor, draftCampaign, mondayOf, type SocialChannel } from '@/features/ads/social';
import { writeWeekDrafts } from '@/server/actions/ads';
import { photoUrl } from '@/lib/photo';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Social drafts', path: '/admin/marketing/social', noindex: true, description: 'The week of Facebook Page and Instagram drafts written from the fleet: approve, edit, copy and post.' });
type Draft = { id: string; slot_date: string; weekday: string; kind: string; channels: SocialChannel[]; car: string | null; car_code: string | null; caption: string; link: string | null; photos: string[];
  status: string; source: string; edited: boolean; approved_by: string | null; posted: Record<string, { url?: string; how?: string; at?: string }>; publish_error: string | null };
type Data = { week: string; today: string; enabled: boolean; drafts: Draft[]; meta: { usable: boolean; enabled: boolean; instagram: boolean } };
const CH: Record<SocialChannel, string> = { instagram: 'Instagram', facebook_page: 'Facebook Page' };
const STATUS: Record<string, [string, string]> = { draft: ['draft', 'Waiting for approval'], approved: ['published', 'Approved'], posted: ['closed', 'Posted'], skipped: ['closed', 'Skipped'] };

// Admin > Marketing > Social drafts (migration 0167, the spec's tasks 7 and 8): a week of drafts written from the fleet
// (a new or featured car on Monday, the owner program on Tuesday, the cars free this weekend on Thursday, the requirements
// on Friday, a price highlight or a seasonal trip on Sunday). Approve or edit each, then copy and post it and paste the
// post's address. Publishing through Meta is built and stays off until the tokens are entered (Settings > Meta publishing).
export default async function SocialDrafts({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([page('/admin/marketing/social'), searchParams]);
  const d = await read<Data>('social_drafts', { week: sp.week && /^\d{4}-\d{2}-\d{2}$/.test(sp.week) ? sp.week : undefined });
  const refresh = ['/admin/marketing/social'];
  const days = Array.from({ length: 7 }, (_, i) => addDays(d.week, i));
  const label = (day: string) => new Date(`${day}T12:00:00Z`).toLocaleDateString('en-CA', { weekday: 'long', month: 'short', day: 'numeric', timeZone: 'UTC' });
  return (<>
    <PageHead kicker="Marketing" title="Social drafts" purpose="Posts for the Facebook Page and Instagram, written from the fleet each week. Nothing is posted until a person approves it.">
      <form action={writeWeekDrafts}><input type="hidden" name="week" value={d.week} /><button className="btn btn--primary btn--sm" type="submit" data-testid="ads-write-week">Write drafts for this week</button></form>
    </PageHead>
    <MarketingTabs current="/admin/marketing/social" />
    <nav className="row" aria-label="Weeks" style={{ gap: '0.75rem', alignItems: 'center', margin: '0 0 1rem' }}>
      <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/admin/marketing/social?week=${addDays(d.week, -7)}`}>Previous week</Link>
      <b>Week of {label(d.week)}</b>
      <Link prefetch={false} className="btn btn--ghost btn--sm" href={`/admin/marketing/social?week=${addDays(d.week, 7)}`}>Next week</Link>
      {mondayOf(d.today) !== d.week && <Link prefetch={false} className="link small" href="/admin/marketing/social">This week</Link>}
    </nav>
    {sp.added !== undefined && <p className="small" role="status" data-testid="ads-week-written">{sp.added === '0' ? 'Every day that can be drafted already has its draft.' : `${sp.added} drafts written.`}</p>}
    <p className="small muted">{d.meta.usable ? 'Meta publishing is on: approved posts go out on their day, and the post links are recorded here.' : <>Copy and post by hand, then paste the post&apos;s address. Publishing through Meta stays off until the tokens are entered in <Link prefetch={false} className="link" href="/admin/settings/meta-publishing">Settings &gt; Meta publishing</Link>.</>}
      {' '}Wednesday&apos;s walkaround video and Saturday&apos;s handover story are filmed by field staff (no renter shown without written consent).{!d.enabled ? ' Automatic drafts are off in Program settings.' : ''}</p>
    <div className="stack" data-testid="ads-week">
      {days.map((day) => {
        const items = d.drafts.filter((x) => x.slot_date === day);
        return (
          <Card key={day} title={label(day)} testId={`ads-day-${day}`}>
            {items.length === 0 ? <p className="small muted">No draft for this day.</p> : items.map((x) => {
              const [tone, words] = STATUS[x.status] ?? ['draft', x.status];
              return (
                <article key={x.id} className="stack" style={{ borderTop: '1px solid var(--line)', paddingTop: '0.75rem' }} data-testid={`ads-draft-${x.kind}`}>
                  <p className="row" style={{ gap: '0.5rem', flexWrap: 'wrap', alignItems: 'center' }}><b>{KIND_WORDS[x.kind] ?? x.kind}</b>{x.car ? <span className="small">{x.car}</span> : null}
                    <Badge s={tone}>{words}</Badge><span className="small muted">for {x.channels.map((c) => CH[c]).join(' and ')}{x.edited ? ', edited' : ''}{x.approved_by ? `, approved by ${x.approved_by}` : ''}</span></p>
                  {x.publish_error && <p className="alert alert--error small" role="alert"><span>Meta refused it: {x.publish_error}</span></p>}
                  {x.channels.map((ch) => {
                    const tracked = x.link ? withUtm(x.link, ch, 'social', draftCampaign(x)) : null;
                    return <CopyText key={ch} label={`${CH[ch]} caption`} value={captionFor(x.caption, ch, x.link, tracked)} rows={Math.min(12, x.caption.split('\n').length + 3)} max={ch === 'instagram' ? 2200 : 3000} testId={`ads-caption-${x.kind}-${ch}`} />;
                  })}
                  {x.link && x.channels.includes('instagram') && <CopyText label="Link for the Instagram bio" value={withUtm(x.link, 'instagram', 'social', draftCampaign(x))} />}
                  {x.photos.length > 0 && <div className="row" style={{ gap: '0.5rem', flexWrap: 'wrap' }}>{x.photos.map((p, i) => (
                    <a key={p} href={photoUrl(p)} target="_blank" rel="noopener" className="small" style={{ display: 'inline-block', width: '6rem' }}>
                      {/* eslint-disable-next-line @next/next/no-img-element */}
                      <img src={photoUrl(p)} alt={`Photo ${i + 1}${x.car ? ` of the ${x.car}` : ''}`} loading="lazy" style={{ width: '100%', aspectRatio: '4 / 3', objectFit: 'cover', borderRadius: '4px', display: 'block' }} />{i + 1}</a>))}</div>}
                  <p className="ad-actions">
                    {x.status !== 'posted' && <Act action="social_draft_save" payload={{ id: x.id }} label="Edit" testId={`ads-edit-${x.kind}`} refresh={refresh} done="Saved: approve it again."
                      fields={[{ name: 'caption', label: 'Caption (on the Facebook Page the link is added in the text)', type: 'textarea', value: x.caption, required: true },
                        { name: 'channels', label: 'Channels (instagram, facebook_page)', type: 'text', value: x.channels.join(', ') }, { name: 'slot_date', label: 'Day', type: 'date', value: x.slot_date }]} />}
                    {x.status === 'draft' && <Act action="social_draft_decide" payload={{ id: x.id, action: 'approve' }} label="Approve" variant="primary" testId={`ads-approve-${x.kind}`} refresh={refresh} done="Approved." />}
                    {x.status === 'approved' && <Act action="social_draft_decide" payload={{ id: x.id, action: 'unapprove' }} label="Back to draft" refresh={refresh} done="Back to draft." />}
                    {(x.status === 'draft' || x.status === 'approved') && <Act action="social_draft_decide" payload={{ id: x.id, action: 'skip' }} label="Skip" refresh={refresh} done="Skipped." />}
                    {x.status === 'skipped' && <Act action="social_draft_decide" payload={{ id: x.id, action: 'restore' }} label="Restore" refresh={refresh} done="Back to draft." />}
                    {x.status === 'approved' && x.channels.filter((ch) => !x.posted?.[ch]).map((ch) => (
                      <Act key={ch} action="social_draft_posted" payload={{ id: x.id, channel: ch }} label={`Posted on ${CH[ch]}`} testId={`ads-posted-${x.kind}-${ch}`} refresh={refresh} done="Recorded."
                        fields={[{ name: 'url', label: 'The post\'s address (https://...)', type: 'text', wide: true }]} />))}
                  </p>
                  {Object.keys(x.posted ?? {}).length > 0 && <ul className="small">{Object.entries(x.posted).map(([ch, p]) => <li key={ch}>{CH[ch as SocialChannel] ?? ch}: {p.how === 'api' ? 'published through Meta' : 'posted by hand'}{p.url ? <> · <a className="link" href={p.url} target="_blank" rel="noopener noreferrer">open the post</a></> : null}</li>)}</ul>}
                </article>);
            })}
          </Card>);
      })}
    </div>
    <Act action="social_draft_save" label="Add a post of your own" testId="ads-add-post" refresh={refresh} done="Added: approve it when ready."
      fields={[{ name: 'slot_date', label: 'Day', type: 'date', value: d.week >= d.today ? d.week : d.today, required: true }, { name: 'caption', label: 'Caption', type: 'textarea', required: true },
        { name: 'channels', label: 'Channels (instagram, facebook_page)', type: 'text', value: 'instagram, facebook_page' }, { name: 'link', label: 'Link (https://...)', type: 'text' }]} />
  </>);
}
