'use client';
import { useCallback, useEffect, useRef, useState } from 'react';
import { staffDo, staffRead } from '@/server/actions/staff-tools';
import { FPS, BITRATE, MAX_BYTES, VIDEO_H, VIDEO_W, drawFrame, pickMime, videoSeconds, type VideoKit } from './video';

// Release 36b (2210): "Make a short video" for a car: a 9:16 slideshow of its real approved photos with the price, the call
// to action and the brand (Program settings), drawn and recorded in this browser, then saved for download and for the post
// scheduler. On the listing page and in the Marketplace kit (Admin, Fleet, customer service, Sales).
type Video = { id: string; path: string; mime: string; seconds: number; bytes: number; at: string };
type Kit = VideoKit & { vehicle: string; photos: string[]; videos: Video[] };
const mb = (b: number) => `${(b / 1024 / 1024).toFixed(1)} MB`;

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((res, rej) => { const i = new Image(); i.decoding = 'async'; i.onload = () => res(i); i.onerror = () => rej(new Error('A photo could not be loaded')); i.src = src; });
}

/** Records the video in real time from the canvas (the browser's own encoder). */
async function record(kit: Kit, onProgress: (p: number) => void): Promise<{ blob: Blob; ext: string; seconds: number }> {
  const mime = pickMime((t) => typeof MediaRecorder !== 'undefined' && MediaRecorder.isTypeSupported(t));
  if (!mime) throw new Error('This browser cannot record video: use Chrome, Edge or Safari on a computer.');
  const imgs = await Promise.all(kit.photos.map((_, i) => loadImage(`/api/social/video?vehicle=${kit.vehicle}&photo=${i}`)));
  const sizes = imgs.map((i) => ({ w: i.naturalWidth, h: i.naturalHeight }));
  const canvas = document.createElement('canvas');
  canvas.width = VIDEO_W; canvas.height = VIDEO_H;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('This browser cannot draw the video.');
  const seconds = videoSeconds(imgs.length, Number(kit.seconds_per_photo) || 2.5);
  drawFrame(ctx, imgs, sizes, kit, 0);
  const stream = canvas.captureStream(FPS);
  const rec = new MediaRecorder(stream, { mimeType: mime.mime, videoBitsPerSecond: BITRATE });
  const chunks: Blob[] = [];
  rec.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
  const stopped = new Promise<void>((res) => { rec.onstop = () => res(); });
  rec.start(1000);
  const t0 = performance.now();
  await new Promise<void>((res) => {
    const tick = () => {
      const t = (performance.now() - t0) / 1000;
      drawFrame(ctx, imgs, sizes, kit, Math.min(t, seconds - 0.001));
      onProgress(Math.min(1, t / seconds));
      if (t >= seconds) { res(); return; }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
  rec.stop();
  await stopped;
  stream.getTracks().forEach((t) => t.stop());
  return { blob: new Blob(chunks, { type: mime.type }), ext: mime.ext, seconds };
}

export function ShortVideo({ vehicle }: { vehicle: string }) {
  const [kit, setKit] = useState<Kit | null>(null);
  const [state, setState] = useState<{ busy: boolean; progress: number; msg: { ok: boolean; text: string } | null }>({ busy: false, progress: 0, msg: null });
  const [tick, setTick] = useState(0);
  const alive = useRef(true);
  useEffect(() => () => { alive.current = false; }, []);
  useEffect(() => { let on = true; void staffRead<Kit>('social_video_kit', { vehicle }).then((r) => { if (on && r.ok) setKit(r.data); }); return () => { on = false; }; }, [vehicle, tick]);
  const make = useCallback(async () => {
    if (!kit) return;
    setState({ busy: true, progress: 0, msg: { ok: true, text: 'Recording: keep this tab open and in front until it is done.' } });
    try {
      const v = await record(kit, (p) => { if (alive.current) setState((s) => ({ ...s, progress: p })); });
      if (v.blob.size > MAX_BYTES) throw new Error(`The video is ${mb(v.blob.size)}: lower Program settings' photos a video and try again.`);
      const fd = new FormData();
      fd.set('vehicle', vehicle); fd.set('seconds', String(v.seconds)); fd.set('file', new File([v.blob], `video.${v.ext}`, { type: v.blob.type }));
      const r = await fetch('/api/social/video', { method: 'POST', body: fd });
      const j = (await r.json().catch(() => ({}))) as { ok?: boolean; message?: string };
      if (!r.ok || !j.ok) throw new Error(j.message ?? 'The video was not saved.');
      if (alive.current) { setState({ busy: false, progress: 1, msg: { ok: true, text: `Saved (${v.seconds} s, ${mb(v.blob.size)}). Download it below or schedule it in Social posts.` } }); setTick((n) => n + 1); }
    } catch (e) {
      if (alive.current) setState({ busy: false, progress: 0, msg: { ok: false, text: e instanceof Error ? e.message : 'The video could not be made.' } });
    }
  }, [kit, vehicle]);
  if (!kit) return null;
  const remove = (id: string) => { void staffDo<Kit>('social_video_remove', { id }).then((r) => { if (r.ok) setKit(r.data); else setState((s) => ({ ...s, msg: { ok: false, text: r.message } })); }); };
  return (
    <section className="stack" data-testid="short-video" aria-labelledby={`sv-${vehicle}`}>
      <h3 className="d4" id={`sv-${vehicle}`}>Short video</h3>
      <p className="small muted">A 9:16 video for Reels, TikTok and Stories from this car&apos;s {kit.photos.length} approved photo{kit.photos.length === 1 ? '' : 's'}: a slow zoom on each, {kit.brand} at the top, {kit.cta ? <>&ldquo;{kit.cta}&rdquo;</> : 'the call to action'} at the bottom. Made in this browser, free.</p>
      {kit.photos.length < 2 ? <p className="small">Approve at least two photos of the car first.</p> : (
        <p className="row" style={{ gap: '0.5rem', alignItems: 'center' }}>
          <button className="btn btn--primary btn--sm" type="button" disabled={state.busy} onClick={() => void make()} data-testid="short-video-make">{state.busy ? `Recording… ${Math.round(state.progress * 100)}%` : 'Make a short video'}</button>
          <span className="small muted">About {videoSeconds(kit.photos.length, Number(kit.seconds_per_photo) || 2.5)} seconds.</span>
        </p>)}
      {state.msg && <p className={`alert ${state.msg.ok ? 'alert--ok' : 'alert--error'}`} role={state.msg.ok ? 'status' : 'alert'}><span>{state.msg.text}</span></p>}
      {kit.videos.length > 0 && <ul className="stack" data-testid="short-video-list">{kit.videos.map((v) => (
        <li key={v.id} className="row" style={{ gap: '0.75rem', alignItems: 'center', flexWrap: 'wrap' }}>
          <video src={`/api/social/video?vehicle=${vehicle}&video=${v.id}`} width={108} height={192} controls preload="none" muted playsInline style={{ background: '#000', borderRadius: '4px' }} />
          <span className="small">{new Date(v.at).toLocaleString('en-CA', { dateStyle: 'medium', timeStyle: 'short' })} · {v.seconds} s · {mb(v.bytes)} · {v.mime === 'video/mp4' ? 'MP4' : 'WebM'}</span>
          <a className="btn btn--ghost btn--sm" href={`/api/social/video?vehicle=${vehicle}&video=${v.id}`} download data-testid="short-video-download">Download</a>
          <button className="btn btn--ghost btn--sm" type="button" onClick={() => remove(v.id)}>Remove</button>
        </li>))}</ul>}
    </section>
  );
}
