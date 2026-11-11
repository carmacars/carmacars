'use client';
import { useCallback, useEffect, useState, useTransition } from 'react';
import { staffDo, staffRead } from '@/server/actions/staff-tools';
import { photoUrl } from '@/lib/photo';
import { CopyText } from '@/features/ads/CopyText';
import Link from '@/components/Link';

// Release 36b (2220): the social post scheduler. Marketing staff queue a post for a time: the Facebook Page, Instagram or
// TikTok, a photo or a short video, the caption from a draft or typed. With Meta publishing connected (Admin > Settings >
// Meta publishing) Facebook and Instagram go out by themselves at their time (the pg_cron job and the Worker); without it,
// and always for TikTok (its posting API needs app review), the post is due here to copy, download and post by hand.
type Channel = 'facebook_page' | 'instagram' | 'tiktok';
type Post = { id: string; channel: Channel; media_kind: 'photo' | 'video' | 'none'; media_path: string | null; video_id: string | null; vehicle_id: string | null; car: string | null;
  caption: string; link: string | null; scheduled_at: string; status: 'queued' | 'due' | 'posting' | 'posted' | 'failed' | 'cancelled'; how: 'api' | 'hand' | null;
  post_url: string | null; error: string | null; by: string | null; log: Array<{ at: string; event: string; detail: string | null }> };
type Data = { meta: { connected: boolean; instagram: boolean; last_error: string | null }; posts: Post[];
  drafts: Array<{ id: string; day: string; kind: string; car: string | null; caption: string; link: string | null; photo: string | null }>;
  videos: Array<{ id: string; vehicle_id: string; car: string; mime: string; seconds: number; at: string }> };
const CH: Record<Channel, string> = { facebook_page: 'Facebook Page', instagram: 'Instagram', tiktok: 'TikTok' };
const ST: Record<Post['status'], string> = { queued: 'Scheduled', due: 'Due: post it now', posting: 'Being posted', posted: 'Posted', failed: 'Failed', cancelled: 'Cancelled' };
const when = (s: string) => new Date(s).toLocaleString('en-CA', { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
const localNow = () => { const d = new Date(Date.now() + 60 * 60 * 1000); d.setMinutes(0, 0, 0); return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16); };
const TIKTOK_STEPS = ['Download the video below to your phone.', 'Open TikTok, tap +, choose the video from your camera roll.', 'Paste the caption (copy it below) and add 3 to 5 hashtags.',
  'Post it, open the post, tap Share > Copy link.', 'Press "Posted by hand" here and paste the link.'];

export function SocialQueue({ admin = false }: { admin?: boolean }) {
  const [d, setD] = useState<Data | null>(null);
  const [tick, setTick] = useState(0);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();
  const [form, setForm] = useState({ channel: 'instagram' as Channel, at: localNow(), draft: '', caption: '', video: '', usePhoto: true });
  const load = useCallback(() => setTick((n) => n + 1), []);
  useEffect(() => { let on = true; void staffRead<Data>('social_queue').then((r) => { if (on && r.ok) setD(r.data); }); return () => { on = false; }; }, [tick]);
  if (!d) return null;
  const draft = d.drafts.find((x) => x.id === form.draft) ?? null;
  const add = () => start(async () => {
    const r = await staffDo('social_queue_add', { channel: form.channel, scheduled_at: new Date(form.at).toISOString(), draft: form.draft || undefined, caption: form.caption || undefined,
      video: form.video || undefined, photo: !form.video && form.usePhoto && draft?.photo ? draft.photo : undefined });
    setMsg(r.ok ? { ok: true, text: `Scheduled for ${when(new Date(form.at).toISOString())}.` } : { ok: false, text: r.message });
    if (r.ok) { setForm((f) => ({ ...f, caption: '', draft: '', video: '' })); load(); }
  });
  const act = (id: string, action: 'cancel' | 'posted' | 'retry') => {
    let url: string | undefined;
    if (action === 'posted') { const u = window.prompt('The post\'s address (https://...), or leave empty'); if (u === null) return; url = u.trim() || undefined; }
    start(async () => { const r = await staffDo('social_queue_act', { id, action, url }); setMsg(r.ok ? { ok: true, text: action === 'cancel' ? 'Cancelled.' : action === 'retry' ? 'Scheduled again.' : 'Recorded as posted.' } : { ok: false, text: r.message }); if (r.ok) load(); });
  };
  const open = d.posts.filter((p) => ['queued', 'due', 'posting', 'failed'].includes(p.status));
  const done = d.posts.filter((p) => !['queued', 'due', 'posting', 'failed'].includes(p.status));
  const media = (p: Post) => p.media_kind === 'video' && p.video_id && p.vehicle_id ? `/api/social/video?vehicle=${p.vehicle_id}&video=${p.video_id}` : p.media_path ? photoUrl(p.media_path) : null;
  const row = (p: Post) => (
    <li key={p.id} className="stack" style={{ borderTop: '1px solid var(--line)', paddingTop: '0.75rem' }} data-testid={`sq-${p.channel}`} data-status={p.status}>
      <p className="row" style={{ gap: '0.5rem', flexWrap: 'wrap' }}><b>{CH[p.channel]}</b><span className="small">{when(p.scheduled_at)}</span><span className="badge">{ST[p.status]}{p.how === 'api' ? ' through Meta' : p.how === 'hand' ? ' by hand' : ''}</span>
        {p.car && <span className="small muted">{p.car}</span>}<span className="small muted">{p.media_kind === 'none' ? 'text only' : p.media_kind}{p.by ? ` · by ${p.by}` : ''}</span></p>
      {p.error && <p className="alert alert--error small" role="alert"><span>Meta: {p.error}</span></p>}
      {p.channel === 'tiktok' && p.status === 'due' && <ol className="small" data-testid="sq-tiktok-steps">{TIKTOK_STEPS.map((s) => <li key={s}>{s}</li>)}</ol>}
      {(p.status === 'due' || p.status === 'failed' || p.status === 'queued') && <CopyText label="Caption" value={p.link && p.channel === 'facebook_page' ? `${p.caption}\n\n${p.link}` : p.caption} rows={Math.min(8, p.caption.split('\n').length + 2)} />}
      <p className="row" style={{ gap: '0.5rem', flexWrap: 'wrap' }}>
        {media(p) && <a className="btn btn--ghost btn--sm" href={media(p)!} download target="_blank" rel="noreferrer" data-testid="sq-download">Download the {p.media_kind}</a>}
        {['queued', 'due', 'failed'].includes(p.status) && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => act(p.id, 'posted')} data-testid="sq-posted">Posted by hand</button>}
        {p.status === 'failed' && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => act(p.id, 'retry')}>Try again</button>}
        {['queued', 'due', 'failed'].includes(p.status) && <button className="btn btn--ghost btn--sm" type="button" disabled={pending} onClick={() => act(p.id, 'cancel')}>Cancel</button>}
        {p.post_url && <a className="link small" href={p.post_url} target="_blank" rel="noopener noreferrer">Open the post</a>}
      </p>
      <details className="small"><summary>Log</summary><ul>{p.log.map((l, i) => <li key={i}>{when(l.at)}: {l.event}{l.detail ? ` (${l.detail})` : ''}</li>)}</ul></details>
    </li>);
  return (
    <section className="stack" data-testid="social-queue" aria-labelledby="sq-h">
      <h2 className="d4" id="sq-h">Scheduled posts</h2>
      {d.meta.connected
        ? <p className="small" data-testid="sq-meta-on">Meta is connected: Facebook{d.meta.instagram ? ' and Instagram' : ''} posts go out by themselves at their time. TikTok is always posted by hand (its posting API needs TikTok&apos;s app review).</p>
        : <p className="alert small" data-testid="sq-connect-meta"><span><b>Connect Meta</b> to post Facebook and Instagram by themselves: {admin ? <Link prefetch={false} className="link" href="/admin/settings/meta-publishing">Settings &gt; Meta publishing</Link> : 'ask an Admin (Settings > Meta publishing)'} (the Page id, the Instagram business account id and a Page token). Until then this is a queue: each post is due at its time to copy, download and post by hand. TikTok is always by hand.</span></p>}
      {d.meta.last_error && d.meta.connected && <p className="small muted">Meta&apos;s last refusal: {d.meta.last_error}</p>}
      <fieldset className="stack" disabled={pending} data-testid="sq-form">
        <legend className="small"><b>Schedule a post</b></legend>
        <div className="row" style={{ gap: '0.75rem', flexWrap: 'wrap' }}>
          <label className="small">Where <select className="select" value={form.channel} onChange={(e) => setForm({ ...form, channel: e.target.value as Channel })} data-testid="sq-channel">
            {(Object.keys(CH) as Channel[]).map((c) => <option key={c} value={c}>{CH[c]}</option>)}</select></label>
          <label className="small">When <input className="input" type="datetime-local" value={form.at} onChange={(e) => setForm({ ...form, at: e.target.value })} data-testid="sq-when" /></label>
          <label className="small">Caption from a draft <select className="select" value={form.draft} onChange={(e) => setForm({ ...form, draft: e.target.value })} data-testid="sq-draft">
            <option value="">None (write it below)</option>{d.drafts.map((x) => <option key={x.id} value={x.id}>{x.day} · {x.kind.replace(/_/g, ' ')}{x.car ? ` · ${x.car}` : ''}</option>)}</select></label>
          <label className="small">Video <select className="select" value={form.video} onChange={(e) => setForm({ ...form, video: e.target.value })} data-testid="sq-video">
            <option value="">None</option>{d.videos.map((v) => <option key={v.id} value={v.id}>{v.car} · {v.seconds} s · {v.mime === 'video/mp4' ? 'MP4' : 'WebM'}</option>)}</select></label>
        </div>
        {draft?.photo && !form.video && <label className="small"><input type="checkbox" checked={form.usePhoto} onChange={(e) => setForm({ ...form, usePhoto: e.target.checked })} /> Use the draft&apos;s photo</label>}
        <label className="small">Caption {draft ? '(empty: the draft\'s caption)' : ''}<textarea className="input" rows={3} maxLength={2200} value={form.caption} onChange={(e) => setForm({ ...form, caption: e.target.value })} placeholder={draft?.caption ?? ''} data-testid="sq-caption" /></label>
        <p className="small muted">Instagram needs a photo or an MP4 video; TikTok a video (make one with &ldquo;Make a short video&rdquo; on the listing or in the Marketplace kit).</p>
        <p><button className="btn btn--primary btn--sm" type="button" onClick={add} data-testid="sq-add">Schedule</button></p>
      </fieldset>
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
      {open.length === 0 ? <p className="small muted">Nothing scheduled.</p> : <ul className="stack" data-testid="sq-open">{open.map(row)}</ul>}
      {done.length > 0 && <details><summary className="small">Posted and cancelled, last two weeks ({done.length})</summary><ul className="stack">{done.map(row)}</ul></details>}
    </section>
  );
}
