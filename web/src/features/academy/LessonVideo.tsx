'use client';
import { useCallback, useEffect, useRef, useState } from 'react';
import { staffRead } from '@/server/actions/staff-tools';
import type { Scene } from './model';
import { LESSON_BITRATE, LESSON_FPS, LESSON_H, LESSON_MAX_BYTES, LESSON_W, drawLesson, pickMime, timeline } from './video';

// Release 37 (2301): an academy lesson as a real video file (MP4 or WebM), free: the first person to press "Watch as video"
// records it in their browser while it plays (the scenes drawn on a canvas, MediaRecorder), and it is saved to the site's
// private storage for everyone after; an Admin renders the missing ones in one go (RenderAllVideos). A changed lesson makes
// its video stale, so the next press records it again.
type Video = { id: string; mime: string; seconds: number; bytes: number; at: string } | null;
type Row = { lesson: string; title: string; scenes: Scene[]; video: Video };
const mb = (b: number) => `${(b / 1024 / 1024).toFixed(1)} MB`;

/** Records a lesson on the given canvas (shown while it records) and saves it; resolves with the saved video list. */
async function recordAndSave(canvas: HTMLCanvasElement, row: { lesson: string; title: string; scenes: Scene[] }, onProgress: (p: number) => void): Promise<void> {
  const mime = pickMime((t) => typeof MediaRecorder !== 'undefined' && MediaRecorder.isTypeSupported(t));
  if (!mime) throw new Error('This browser cannot record video: use Chrome, Edge or Safari on a computer.');
  canvas.width = LESSON_W; canvas.height = LESSON_H;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('This browser cannot draw the video.');
  const tl = timeline(row.scenes);
  drawLesson(ctx, row.title, row.scenes, tl, 0);
  const stream = canvas.captureStream(LESSON_FPS);
  const rec = new MediaRecorder(stream, { mimeType: mime.mime, videoBitsPerSecond: LESSON_BITRATE });
  const chunks: Blob[] = [];
  rec.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
  const stopped = new Promise<void>((res) => { rec.onstop = () => res(); });
  rec.start(1000);
  const t0 = performance.now();
  await new Promise<void>((res) => {
    const tick = () => {
      const t = (performance.now() - t0) / 1000;
      drawLesson(ctx, row.title, row.scenes, tl, Math.min(t, tl.total - 0.001));
      onProgress(Math.min(1, t / tl.total));
      if (t >= tl.total) { res(); return; }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  });
  rec.stop();
  await stopped;
  stream.getTracks().forEach((t) => t.stop());
  const blob = new Blob(chunks, { type: mime.type });
  if (blob.size > LESSON_MAX_BYTES) throw new Error(`The video is ${mb(blob.size)}, over the 80 MB the site keeps.`);
  const fd = new FormData();
  fd.set('lesson', row.lesson); fd.set('seconds', String(tl.total)); fd.set('file', new File([blob], `lesson.${mime.ext}`, { type: mime.type }));
  const r = await fetch('/api/academy/video', { method: 'POST', body: fd });
  const j = (await r.json().catch(() => ({}))) as { ok?: boolean; message?: string };
  if (!r.ok || !j.ok) throw new Error(j.message ?? 'The video was not saved.');
}

/** "Watch as video" under a lesson's player, for everyone who studies it (Admin and every staff portal). */
export function LessonVideo({ lesson, title, scenes, testId = 'lesson-video' }: { lesson: string; title: string; scenes: Scene[]; testId?: string }) {
  const [video, setVideo] = useState<Video | undefined>(undefined);
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState<number | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const alive = useRef(true);
  useEffect(() => () => { alive.current = false; }, []);
  const load = useCallback(() => staffRead<{ lessons: Row[] }>('academy_videos', { lesson }).then((r) => { if (alive.current) setVideo(r.ok ? r.data.lessons[0]?.video ?? null : null); }), [lesson]);
  useEffect(() => { void load(); }, [load]);
  if (video === undefined || !scenes.length) return null;
  const watch = async () => {
    setOpen(true); setMsg(null);
    if (video) return;
    setBusy(0);
    // the canvas is in the page once open: record on it
    await new Promise((r) => requestAnimationFrame(r));
    try {
      if (!canvas.current) throw new Error('The video could not be drawn.');
      await recordAndSave(canvas.current, { lesson, title, scenes }, (p) => { if (alive.current) setBusy(p); });
      await load();
    } catch (e) { if (alive.current) setMsg(e instanceof Error ? e.message : 'The video could not be made.'); }
    if (alive.current) setBusy(null);
  };
  const src = `/api/academy/video?lesson=${lesson}`;
  return (
    <div className="stack" data-testid={testId}>
      <p className="row" style={{ gap: '0.5rem', alignItems: 'center', flexWrap: 'wrap' }}>
        {!open && <button type="button" className="btn btn--ghost btn--sm" onClick={() => void watch()} data-testid={`${testId}-watch`}>Watch as video</button>}
        {video && <a className="btn btn--ghost btn--sm" href={`${src}&download=1`} download data-testid={`${testId}-download`}>Download video ({video.mime === 'video/mp4' ? 'MP4' : 'WebM'}, {mb(video.bytes)})</a>}
        {!video && !open && <span className="small muted">The first time, the video is made in your browser while you watch it, then saved for everyone.</span>}
      </p>
      {open && video && <video src={src} controls playsInline preload="metadata" style={{ inlineSize: '100%', background: '#000', borderRadius: '6px' }} aria-label={`Lesson video: ${title}`} />}
      {open && !video && <canvas ref={canvas} width={LESSON_W} height={LESSON_H} style={{ inlineSize: '100%', background: '#000', borderRadius: '6px' }} aria-label={`Lesson video: ${title}`} />}
      {busy !== null && <p className="small" role="status">Making the video: {Math.round(busy * 100)}%. Keep this tab open and in front until it is done.</p>}
      {msg && <p className="alert alert--error" role="alert"><span>{msg}</span></p>}
    </div>
  );
}

/** Admin > Academy: render every lesson without a current video, one after the other, on this page. */
export function RenderAllVideos() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [at, setAt] = useState<{ i: number; p: number } | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const load = useCallback(() => staffRead<{ lessons: Row[] }>('academy_videos', {}).then((r) => { if (r.ok) setRows(r.data.lessons); }), []);
  useEffect(() => { void load(); }, [load]);
  if (!rows) return null;
  const missing = rows.filter((r) => !r.video);
  const run = async () => {
    setMsg(null);
    let done = 0;
    for (let i = 0; i < missing.length; i++) {
      setAt({ i, p: 0 });
      await new Promise((r) => requestAnimationFrame(r));
      try {
        if (!canvas.current) throw new Error('The video could not be drawn.');
        await recordAndSave(canvas.current, missing[i]!, (p) => setAt({ i, p }));
        done++;
      } catch (e) { setMsg({ ok: false, text: `${missing[i]!.title}: ${e instanceof Error ? e.message : 'not made'}` }); break; }
    }
    setAt(null);
    if (done) setMsg((m) => m ?? { ok: true, text: `${done} lesson video${done === 1 ? '' : 's'} made and saved.` });
    await load();
  };
  const seconds = missing.reduce((s, r) => s + timeline(r.scenes).total, 0);
  return (
    <section className="pt-card ad-card stack" aria-labelledby="rv-h" data-testid="render-videos">
      <h2 className="d4" id="rv-h">Lesson videos</h2>
      <p className="small">{rows.length - missing.length} of {rows.length} lessons have a current video (MP4 or WebM, downloadable from each lesson). {missing.length > 0 && <>Making the other {missing.length} takes about {Math.ceil(seconds / 60)} minutes: they play here, in this browser, for free.</>}</p>
      {missing.length > 0 && !at && <p><button type="button" className="btn btn--primary btn--sm" onClick={() => void run()} data-testid="render-videos-run">Render videos</button></p>}
      {at && <><p className="small" role="status">Making {at.i + 1} of {missing.length}: {missing[at.i]?.title} ({Math.round(at.p * 100)}%). Keep this tab open and in front.</p>
        <canvas ref={canvas} width={LESSON_W} height={LESSON_H} style={{ inlineSize: '100%', maxInlineSize: '640px', background: '#000', borderRadius: '6px' }} aria-label="The lesson video being made" /></>}
      {msg && <p className={`alert ${msg.ok ? 'alert--ok' : 'alert--error'}`} role={msg.ok ? 'status' : 'alert'}><span>{msg.text}</span></p>}
    </section>
  );
}
