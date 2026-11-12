'use client';
import Link from '@/components/Link';
import { useCallback, useEffect, useRef, useState } from 'react';
import {
  AUDIO_BITS, AUDIO_TYPES_PREFERRED, cannotRecordWhy, clock, DEFAULT_ANSWER_SECONDS, LOW_SECONDS, MAX_VIDEO_BYTES, VIDEO_BITS, VIDEO_CONSTRAINTS, VIDEO_TYPES,
  type InterviewView, type NextQuestion
} from './ai-interview';

// The AI interview page (migration 0380; release 30, migration 0585: video). The consent, then a camera and microphone
// check (a preview and a sound level), then one question at a time: shown and read aloud, then the answer time (Admin >
// Hiring, Answer time: 2:00 by default) counts down. The applicant presses Record whenever ready inside it; recording
// stops by itself at 0:00 and the answer is sent. Each answer is a short video with sound (about 720p), uploaded straight
// to private storage with its audio track, which the transcript is made from. Retakes only as the setting allows (none by
// default). Without a camera or a microphone the answers are typed, on the same clock. Nothing is recorded before the
// consent.
type Phase = 'reading' | 'ready' | 'recording' | 'review' | 'sending';
type Clip = { video: Blob; audio: Blob; url: string; seconds: number };
type Check = { state: 'idle' | 'asking' | 'ok' | 'go' | 'failed'; why?: string; typedOk?: boolean };
type Msg = { tone: 'ok' | 'error'; text: string } | null;
type Post = (fd: FormData) => Promise<boolean>;

function pick(types: string[]): string {
  if (typeof MediaRecorder === 'undefined') return '';
  for (const t of types) if (MediaRecorder.isTypeSupported?.(t)) return t;
  return '';
}
const recorderOk = () => typeof MediaRecorder !== 'undefined' && pick(VIDEO_TYPES) !== '' && pick(AUDIO_TYPES_PREFERRED) !== '';
/** PUT a file to its signed link, reporting the bytes sent so far. */
function upload(url: string, headers: Record<string, string>, body: Blob, onProgress: (sent: number) => void): Promise<boolean> {
  return new Promise((done) => {
    const x = new XMLHttpRequest();
    x.open('PUT', url);
    for (const [k, v] of Object.entries(headers)) x.setRequestHeader(k, v);
    x.upload.onprogress = (e) => onProgress(e.loaded);
    x.onload = () => done(x.status >= 200 && x.status < 300);
    x.onerror = () => done(false);
    x.send(body);
  });
}
/** The question read aloud by the browser; then() once it is done (or at once without speech). */
function speak(s: string, then?: () => void) {
  let done = false;
  const finish = () => { if (!done) { done = true; then?.(); } };
  try {
    if (typeof window === 'undefined' || !('speechSynthesis' in window)) { finish(); return; }
    window.speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(s);
    u.lang = 'en-US'; u.rate = 0.95;
    u.onend = finish; u.onerror = finish;
    window.speechSynthesis.speak(u);
    // a browser that never says it is done: the clock starts after about the time it takes to read
    setTimeout(finish, Math.min(30_000, 1500 + s.split(/\s+/).length * 450));
  } catch { finish(); }
}
/** The live picture of the camera in a video element. */
function useLive(stream: MediaStream | null) {
  const ref = useRef<HTMLVideoElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (el && stream && el.srcObject !== stream) { el.srcObject = stream; el.play?.().catch(() => undefined); }
  });
  return ref;
}

export function Interview({ token, initial }: { token: string; initial: InterviewView }) {
  const [v, setV] = useState(initial);
  const [agree, setAgree] = useState(false);
  const [check, setCheck] = useState<Check>({ state: 'idle' });
  const [typing, setTyping] = useState(false);
  const [stream, setStream] = useState<MediaStream | null>(null);
  const [level, setLevel] = useState(0);
  const [starting, setStarting] = useState(false);
  const [msg, setMsg] = useState<Msg>(null);
  const meter = useRef<{ ctx: AudioContext; raf: number } | null>(null);
  const live = useLive(stream);
  const q = v.next;
  const total = v.answer_seconds ?? DEFAULT_ANSWER_SECONDS;
  const allowed = v.retakes ?? 0;
  const done = v.state === 'submitted' || v.state === 'scored' || (!q && v.state === 'started');

  const stopMeter = () => { if (meter.current) { cancelAnimationFrame(meter.current.raf); meter.current.ctx.close().catch(() => undefined); meter.current = null; } };
  // the camera and the microphone are let go when the interview is done or the page closes
  useEffect(() => {
    if (!done) return;
    stopMeter();
    stream?.getTracks().forEach((t) => t.stop());
  }, [done, stream]);
  useEffect(() => () => { stopMeter(); try { window.speechSynthesis?.cancel(); } catch { /* none */ } }, []);
  useEffect(() => () => { stream?.getTracks().forEach((t) => t.stop()); }, [stream]);
  // the meter only on the check
  useEffect(() => { if (check.state === 'go') stopMeter(); }, [check.state]);

  async function askDevices() {
    setCheck({ state: 'asking' });
    if (!navigator.mediaDevices?.getUserMedia || !recorderOk()) { setCheck({ state: 'failed', why: cannotRecordWhy(null, false), typedOk: true }); return; }
    try {
      stopMeter();
      const s = await navigator.mediaDevices.getUserMedia({ video: VIDEO_CONSTRAINTS, audio: { echoCancellation: true, noiseSuppression: true } });
      setStream(s);
      setCheck({ state: 'ok' });
      // the sound level: the microphone's loudness, a bar that moves as the applicant speaks
      try {
        const AC = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
        if (AC) {
          const ctx = new AC();
          const an = ctx.createAnalyser(); an.fftSize = 512;
          ctx.createMediaStreamSource(s).connect(an);
          const buf = new Uint8Array(an.fftSize);
          const loop = () => {
            an.getByteTimeDomainData(buf);
            let sum = 0; for (const b of buf) sum += ((b - 128) / 128) ** 2;
            setLevel(Math.min(1, Math.sqrt(sum / buf.length) * 4));
            if (meter.current) meter.current.raf = requestAnimationFrame(loop);
          };
          meter.current = { ctx, raf: requestAnimationFrame(loop) };
        }
      } catch { /* no meter: the preview still shows */ }
    } catch (e) {
      const err = e as { name?: string };
      setCheck({ state: 'failed', why: cannotRecordWhy(err, true), typedOk: err?.name === 'NotFoundError' || err?.name === 'OverconstrainedError' });
    }
  }

  const post: Post = useCallback(async (fd) => {
    try {
      const r = await fetch(`/api/careers/interview/${token}`, { method: 'POST', body: fd });
      const j = (await r.json().catch(() => ({ ok: false, message: 'We could not reach CarmaCars. Check your connection and try again.' }))) as { ok: boolean; view?: InterviewView; message?: string };
      if (!j.ok || !j.view) { setMsg({ tone: 'error', text: j.message ?? 'Something went wrong. Please try again.' }); return false; }
      setV(j.view); setMsg(null); return true;
    } catch { setMsg({ tone: 'error', text: 'We could not reach CarmaCars. Check your connection and try again.' }); return false; }
  }, [token]);

  async function start() {
    setStarting(true);
    const fd = new FormData(); fd.set('start', '1'); fd.set('consent', agree ? '1' : '0');
    await post(fd);
    setStarting(false);
  }

  const head = <p className="small muted">{v.role_title}</p>;
  const alert = msg && <p className={`alert${msg.tone === 'error' ? ' alert--error' : ''}`} role={msg.tone === 'error' ? 'alert' : 'status'} data-testid="iv-msg"><span>{msg.text}</span></p>;
  const mins = total % 60 ? clock(total) : `${total / 60} minute${total === 60 ? '' : 's'}`;

  if (v.state === 'expired') return (<div className="stack-lg" data-testid="iv-expired">{head}<h1 className="d2">This interview link has expired</h1>
    <p>Links work for 7 days. If you still want the role, reply to our email and we will send you a new one.</p>
    <p><Link prefetch={false} className="link" href="/careers">Open roles</Link></p></div>);
  if (done) return (<div className="stack-lg" data-testid="iv-done">{head}
    <h1 className="d2" tabIndex={-1}>Thank you, {v.first_name}. Your interview is done.</h1>
    <p className="lead">Your answers are scored against the role. We will write to you with the next step within two days.</p>
    <p className="small muted">You can close this page.</p></div>);
  if (v.state === 'sent' || v.consent_needed) return (
    <div className="stack-lg" data-testid="iv-intro">
      {head}
      <h1 className="d2">Your interview, {v.first_name}</h1>
      <p className="lead">{v.total} questions, about {Math.max(10, Math.round((v.total * total) / 60))} minutes, on video. Do it now or any time before {new Date(v.expires_at).toLocaleDateString('en-CA', { month: 'long', day: 'numeric', timeZone: 'America/Toronto' })}.</p>
      <p data-testid="iv-prescreen">This interview is the pre-screen to our training academy, and the bar is high: give real examples with names, numbers and what you said. Pass it and your training starts right away.</p>
      <ol className="iv-how">
        <li>First we check your camera and microphone.</li>
        <li>Each question is shown and read aloud. Then you have {mins} to answer: press <b>Record</b> when you are ready and speak to the camera, as you would on a video call.</li>
        <li>Recording stops by itself when the time is up, and your answer is sent. {allowed > 0 ? `You can record an answer again ${allowed === 1 ? 'once' : `${allowed} times`}.` : 'Each answer is recorded once, so take a moment to think before you press Record.'}</li>
      </ol>
      <p className="small muted">Find a quiet, well lit place. Some answers get a short follow-up question. If you leave, open the same link to carry on where you stopped.</p>
      <div className="iv-consent" data-testid="iv-consent">
        <p className="small">{v.consent_text} <Link prefetch={false} className="link" href="/privacy">Privacy policy</Link></p>
        <label className="check"><input type="checkbox" checked={agree} onChange={(e) => setAgree(e.target.checked)} data-testid="iv-agree" /> <span>I agree to the video recording</span></label>
      </div>
      {alert}
      <p><button type="button" className="btn btn--primary btn--lg" disabled={!agree || starting} onClick={start} data-testid="iv-start">{starting ? 'Starting' : 'Start the interview'}</button></p>
    </div>);
  if (!q) return null;

  // the camera and microphone check, before the first question (and again after a reload)
  if (!typing && check.state !== 'go') return (
    <div className="stack-lg" data-testid="iv-check">
      {head}
      <h1 className="d2">Check your camera and microphone</h1>
      <p className="lead">You should see yourself below, and the bar should move when you speak.</p>
      {check.state === 'failed'
        ? <><p className="alert alert--error" role="alert" data-testid="iv-check-why"><span>{check.why}</span></p>
          <p className="row"><button type="button" className="btn btn--primary btn--lg" onClick={askDevices} data-testid="iv-check-retry">Try again</button>
            {check.typedOk && <button type="button" className="btn btn--ghost" onClick={() => setTyping(true)} data-testid="iv-check-typed">Type my answers instead</button>}</p>
          {check.typedOk && <p className="small muted">Typed answers have the same time: {mins} for each.</p>}</>
        : check.state === 'ok'
          ? <>
            <div className="iv-cam"><video ref={live} muted playsInline autoPlay className="iv-video" aria-label="Your camera" data-testid="iv-preview" /></div>
            <div className="iv-meter" role="meter" aria-label="Microphone level" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(level * 100)} data-testid="iv-level">
              <span style={{ width: `${Math.round(level * 100)}%` }} /></div>
            <p className="small muted">Say a few words: the bar moves when we hear you.</p>
            <p><button type="button" className="btn btn--primary btn--lg" onClick={() => setCheck({ state: 'go' })} data-testid="iv-check-go">It works: start the questions</button></p></>
          : <p><button type="button" className="btn btn--primary btn--lg" onClick={askDevices} disabled={check.state === 'asking'} data-testid="iv-check-start">{check.state === 'asking' ? 'Asking for the camera' : 'Turn on my camera and microphone'}</button></p>}
    </div>);

  return <Question key={q.seq} token={token} v={v} q={q} total={total} allowed={allowed} typing={typing} stream={stream} post={post} msg={msg} setMsg={setMsg} head={head} mins={mins} />;
}

// One question: a component of its own (keyed by the question), so each starts with a fresh clock and nothing recorded.
function Question({ token, v, q, total, allowed, typing, stream, post, msg, setMsg, head, mins }: {
  token: string; v: InterviewView; q: NextQuestion; total: number; allowed: number; typing: boolean; stream: MediaStream | null; post: Post;
  msg: Msg; setMsg: (m: Msg) => void; head: React.ReactNode; mins: string;
}) {
  const [phase, setPhase] = useState<Phase>('reading');
  const [left, setLeft] = useState(total);
  const [text, setText] = useState('');
  const [clip, setClip] = useState<Clip | null>(null);
  const [retakes, setRetakes] = useState(0);
  const [sent, setSent] = useState<number | null>(null);
  const heading = useRef<HTMLHeadingElement>(null);
  const deadline = useRef(0);
  const recStart = useRef(0);
  const recs = useRef<{ video: MediaRecorder; audio: MediaRecorder } | null>(null);
  const busy = useRef(false);
  const live = useLive(stream);

  // shown, read aloud, then the clock
  useEffect(() => {
    heading.current?.focus();
    speak(q.text, () => { deadline.current = Date.now() + total * 1000; setLeft(total); setPhase((p) => (p === 'reading' ? 'ready' : p)); });
    return () => { const r = recs.current; if (r) { r.video.ondataavailable = null; r.audio.ondataavailable = null; if (r.video.state === 'recording') r.video.stop(); if (r.audio.state === 'recording') r.audio.stop(); } };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  async function sendClip(c: Clip, used: number) {
    if (busy.current) return;
    busy.current = true; setPhase('sending'); setSent(0);
    try {
      const prep = new FormData(); prep.set('prepare', '1'); prep.set('seq', String(q.seq)); prep.set('video_type', c.video.type); prep.set('audio_type', c.audio.type);
      const r = await fetch(`/api/careers/interview/${token}`, { method: 'POST', body: prep });
      const u = (await r.json().catch(() => ({ ok: false }))) as { ok: boolean; message?: string; video?: { key: string; url: string; headers: Record<string, string> }; audio?: { key: string; url: string; headers: Record<string, string> } };
      if (!u.ok || !u.video || !u.audio) { setMsg({ tone: 'error', text: u.message ?? 'We could not start the upload. Press Send this answer to try again.' }); setPhase('review'); return; }
      const all = c.video.size + c.audio.size;
      let vSent = 0; let aSent = 0;
      const tick = () => setSent(Math.round(((vSent + aSent) / Math.max(all, 1)) * 100));
      const [okV, okA] = await Promise.all([
        upload(u.video.url, u.video.headers, c.video, (n) => { vSent = n; tick(); }),
        upload(u.audio.url, u.audio.headers, c.audio, (n) => { aSent = n; tick(); })
      ]);
      if (!okV || !okA) { setMsg({ tone: 'error', text: 'The upload did not finish. Check your connection, then press Send this answer.' }); setPhase('review'); return; }
      const fd = new FormData();
      fd.set('seq', String(q.seq)); fd.set('mode', 'voice'); fd.set('seconds', String(c.seconds)); fd.set('type', c.audio.type);
      fd.set('audio_key', u.audio.key); fd.set('video_key', u.video.key); fd.set('video_type', c.video.type); fd.set('video_bytes', String(c.video.size)); fd.set('retakes_used', String(used));
      if (await post(fd)) URL.revokeObjectURL(c.url); else setPhase('review');
    } finally { busy.current = false; setSent(null); }
  }
  async function sendText(t: string) {
    if (busy.current) return;
    busy.current = true; setPhase('sending');
    const fd = new FormData(); fd.set('seq', String(q.seq));
    if (t.trim()) { fd.set('mode', 'typed'); fd.set('text', t); } else fd.set('mode', 'none');
    const ok = await post(fd);
    busy.current = false;
    if (!ok) setPhase('ready');
  }

  function record() {
    if (!stream || phase !== 'ready') return;
    setMsg(null);
    try { window.speechSynthesis?.cancel(); } catch { /* none */ }
    const vt = pick(VIDEO_TYPES); const at = pick(AUDIO_TYPES_PREFERRED);
    const video = new MediaRecorder(stream, { mimeType: vt, videoBitsPerSecond: VIDEO_BITS, audioBitsPerSecond: AUDIO_BITS });
    const audio = new MediaRecorder(new MediaStream(stream.getAudioTracks()), { mimeType: at, audioBitsPerSecond: AUDIO_BITS });
    const vc: Blob[] = []; const ac: Blob[] = [];
    video.ondataavailable = (e) => { if (e.data.size) vc.push(e.data); };
    audio.ondataavailable = (e) => { if (e.data.size) ac.push(e.data); };
    let stopped = 0;
    const onStop = () => {
      if (++stopped < 2) return;
      recs.current = null;
      const vb = new Blob(vc, { type: video.mimeType || vt }); const ab = new Blob(ac, { type: audio.mimeType || at });
      if (vb.size > MAX_VIDEO_BYTES) { setMsg({ tone: 'error', text: 'That video is too large to send. Please record a shorter answer.' }); setPhase('ready'); return; }
      const c = { video: vb, audio: ab, url: URL.createObjectURL(vb), seconds: Math.round((Date.now() - recStart.current) / 100) / 10 };
      setClip(c);
      // no retake left, or the time is up: it goes at once; otherwise the applicant watches it and sends it or records again
      if (allowed - retakes <= 0 || deadline.current - Date.now() <= 0) void sendClip(c, retakes);
      else setPhase('review');
    };
    video.onstop = onStop; audio.onstop = onStop;
    recs.current = { video, audio };
    recStart.current = Date.now();
    video.start(1000); audio.start(1000);
    setPhase('recording');
  }
  const stop = () => { const r = recs.current; if (r) { if (r.video.state === 'recording') r.video.stop(); if (r.audio.state === 'recording') r.audio.stop(); } };
  const again = () => { if (clip) URL.revokeObjectURL(clip.url); setClip(null); setRetakes((n) => n + 1); setPhase('ready'); };

  // the clock: at 0:00 recording stops and the answer goes (typed as written; none when nothing was recorded or typed)
  useEffect(() => {
    if (phase === 'reading' || phase === 'sending' || !deadline.current) return;
    const id = setInterval(() => {
      const s = (deadline.current - Date.now()) / 1000;
      setLeft(Math.max(0, s));
      if (s > 0) return;
      clearInterval(id);
      if (phase === 'recording') stop();
      else if (phase === 'review' && clip) void sendClip(clip, retakes);
      else if (phase === 'ready') void sendText(typing ? text : '');
    }, 250);
    return () => clearInterval(id);
  });

  const low = left <= LOW_SECONDS && phase !== 'reading';
  const n = Math.min(v.answered + (q.kind === 'question' ? 1 : 0), v.total);
  const alert = msg && <p className={`alert${msg.tone === 'error' ? ' alert--error' : ''}`} role={msg.tone === 'error' ? 'alert' : 'status'} data-testid="iv-msg"><span>{msg.text}</span></p>;
  return (
    <div className="stack-lg" data-testid="iv-question" data-seq={q.seq} data-kind={q.kind} data-phase={phase}>
      {head}
      <div className="iv-head">
        <div className="iv-progress" aria-hidden="true"><span style={{ width: `${Math.round(((n - 1) / v.total) * 100)}%` }} /></div>
        <p className="iv-step">{q.kind === 'followup' ? 'A short follow-up' : `Question ${n} of ${v.total}`}</p>
        <h1 className="d3 iv-q" tabIndex={-1} ref={heading} data-testid="iv-text">{q.text}</h1>
      </div>
      <p><button type="button" className="btn btn--ghost btn--sm" onClick={() => speak(q.text)} disabled={phase === 'recording'} data-testid="iv-play">Play the question</button></p>
      <p className={`iv-timer${low ? ' is-low' : ''}`} data-testid="iv-timer" data-low={low ? '1' : '0'}>
        {phase === 'reading' ? <>Reading the question. Your {mins} start after it.</> : <><span className="iv-timer__n" role="timer">{clock(left)}</span> left to answer</>}
      </p>
      {alert}
      {!typing && (
        <div className="iv-answer" aria-live="polite">
          {(phase === 'reading' || phase === 'ready' || phase === 'recording') && (
            <div className={`iv-cam${phase === 'recording' ? ' is-rec' : ''}`}>
              <video ref={live} muted playsInline autoPlay className="iv-video" aria-label="Your camera" data-testid="iv-preview" />
              {phase === 'recording' && <span className="iv-cam__rec"><span className="iv-dot is-on" aria-hidden="true" />Recording</span>}
            </div>)}
          {phase === 'ready' && <button type="button" className="btn btn--primary btn--lg iv-rec" onClick={record} data-testid="iv-record"><span className="iv-dot" aria-hidden="true" />{retakes > 0 ? 'Record again' : 'Record'}</button>}
          {phase === 'recording' && <button type="button" className="btn btn--primary btn--lg" onClick={stop} data-testid="iv-stop">{allowed - retakes > 0 ? 'Stop' : 'Stop and send'}</button>}
          {(phase === 'review' || phase === 'sending') && clip && <video controls playsInline src={clip.url} className="iv-video" aria-label="Your answer" data-testid="iv-review" />}
          {phase === 'review' && clip && <div className="row">
            <button type="button" className="btn btn--primary btn--lg" onClick={() => sendClip(clip, retakes)} data-testid="iv-send">Send this answer</button>
            {allowed - retakes > 0 && left > 0 && <button type="button" className="btn btn--ghost" onClick={again} data-testid="iv-again">Record again ({allowed - retakes} left)</button>}
          </div>}
          {phase === 'sending' && <p className="iv-up" role="status" data-testid="iv-uploading">{sent !== null ? `Sending your answer: ${sent}%` : 'Sending your answer'}</p>}
        </div>)}
      {typing && (
        <div className="stack">
          <label className="field"><span className="label">Your answer</span>
            <textarea className="input" rows={6} value={text} maxLength={4000} onChange={(e) => setText(e.target.value)} disabled={phase !== 'ready'} data-testid="iv-typed" /></label>
          <p className="small muted">What you have typed is sent when the time is up.</p>
          <p><button type="button" className="btn btn--primary btn--lg" onClick={() => sendText(text)} disabled={phase !== 'ready' || !text.trim()} data-testid="iv-send-typed">{phase === 'sending' ? 'Sending your answer' : 'Send this answer'}</button></p>
        </div>)}
    </div>
  );
}
