'use client';
import Link from '@/components/Link';
import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { MAX_ANSWER_SECONDS, type InterviewView } from './ai-interview';

// The AI interview page (migration 0380): the consent, then one question at a time, shown and read aloud (the browser's
// speech), answered out loud (the browser records it) or typed. Each answer is sent as soon as the candidate is happy
// with it; the next question (or a follow-up) comes back. Nothing is recorded before the consent.
type Phase = 'idle' | 'recording' | 'review' | 'sending';
const fmt = (s: number) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;

const noop = () => () => undefined;
const recorderReady = () => typeof navigator !== 'undefined' && !!navigator.mediaDevices?.getUserMedia && pickType() !== '';
function pickType(): string {
  if (typeof MediaRecorder === 'undefined') return '';
  for (const t of ['audio/webm;codecs=opus', 'audio/mp4', 'audio/ogg;codecs=opus', 'audio/webm']) if (MediaRecorder.isTypeSupported?.(t)) return t;
  return '';
}

export function Interview({ token, initial }: { token: string; initial: InterviewView }) {
  const [v, setV] = useState(initial);
  const [agree, setAgree] = useState(false);
  const [phase, setPhase] = useState<Phase>('idle');
  const [typing, setTyping] = useState(false);
  const [text, setText] = useState('');
  const [secs, setSecs] = useState(0);
  const [clip, setClip] = useState<{ blob: Blob; url: string; seconds: number } | null>(null);
  const [msg, setMsg] = useState<{ tone: 'ok' | 'error'; text: string } | null>(null);
  const rec = useRef<MediaRecorder | null>(null);
  const chunks = useRef<Blob[]>([]);
  const t0 = useRef(0);
  const tick = useRef<ReturnType<typeof setInterval> | null>(null);
  const heading = useRef<HTMLHeadingElement>(null);
  const q = v.next;

  const speak = useCallback((s: string) => {
    try {
      if (typeof window === 'undefined' || !('speechSynthesis' in window)) return;
      window.speechSynthesis.cancel();
      const u = new SpeechSynthesisUtterance(s);
      u.lang = 'en-US'; u.rate = 0.95;
      window.speechSynthesis.speak(u);
    } catch { /* no speech: the question is on the screen */ }
  }, []);
  // a browser that cannot record (no microphone access, no MediaRecorder) answers in writing
  const canRecord = useSyncExternalStore(noop, recorderReady, () => true);
  // each new question is read aloud and gets the focus
  useEffect(() => {
    if (v.state !== 'started' || !q) return;
    heading.current?.focus();
    speak(q.text);
  }, [q?.seq, v.state]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => () => { if (tick.current) clearInterval(tick.current); try { window.speechSynthesis?.cancel(); } catch { /* none */ } }, []);

  async function post(fd: FormData): Promise<boolean> {
    try {
      const r = await fetch(`/api/careers/interview/${token}`, { method: 'POST', body: fd });
      const j = (await r.json().catch(() => ({ ok: false, message: 'We could not reach CarmaCars. Check your connection and try again.' }))) as { ok: boolean; view?: InterviewView; message?: string };
      if (!j.ok || !j.view) { setMsg({ tone: 'error', text: j.message ?? 'Something went wrong. Please try again.' }); return false; }
      setV(j.view); setMsg(null); return true;
    } catch { setMsg({ tone: 'error', text: 'We could not reach CarmaCars. Check your connection and try again.' }); return false; }
  }

  async function start() {
    setPhase('sending');
    const fd = new FormData(); fd.set('start', '1'); fd.set('consent', agree ? '1' : '0');
    await post(fd);
    setPhase('idle');
  }

  async function record() {
    setMsg(null);
    try { window.speechSynthesis?.cancel(); } catch { /* none */ }
    let stream: MediaStream;
    try { stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true } }); }
    catch { setMsg({ tone: 'error', text: 'The microphone is blocked. Allow it in your browser, or type your answer instead.' }); setTyping(true); return; }
    const type = pickType();
    const r = new MediaRecorder(stream, type ? { mimeType: type } : undefined);
    chunks.current = [];
    r.ondataavailable = (e) => { if (e.data.size) chunks.current.push(e.data); };
    r.onstop = () => {
      stream.getTracks().forEach((t) => t.stop());
      if (tick.current) clearInterval(tick.current);
      const blob = new Blob(chunks.current, { type: (r.mimeType || type || 'audio/webm') });
      const seconds = Math.round((Date.now() - t0.current) / 100) / 10;
      setClip({ blob, url: URL.createObjectURL(blob), seconds });
      setPhase('review');
    };
    rec.current = r;
    t0.current = Date.now(); setSecs(0);
    tick.current = setInterval(() => {
      const s = (Date.now() - t0.current) / 1000;
      setSecs(s);
      if (s >= MAX_ANSWER_SECONDS && rec.current?.state === 'recording') rec.current.stop();
    }, 250);
    r.start(1000);
    setPhase('recording');
  }
  const stop = () => { if (rec.current?.state === 'recording') rec.current.stop(); };
  const again = () => { if (clip) URL.revokeObjectURL(clip.url); setClip(null); setPhase('idle'); };

  async function send() {
    if (!q) return;
    const fd = new FormData();
    fd.set('seq', String(q.seq));
    if (typing) { if (!text.trim()) { setMsg({ tone: 'error', text: 'Type your answer first.' }); return; } fd.set('mode', 'typed'); fd.set('text', text); }
    else if (clip) { fd.set('mode', 'voice'); fd.set('seconds', String(clip.seconds)); fd.set('type', clip.blob.type); fd.set('audio', clip.blob, `answer.${clip.blob.type.includes('mp4') ? 'm4a' : 'webm'}`); }
    else return;
    setPhase('sending');
    const ok = await post(fd);
    if (ok) { if (clip) URL.revokeObjectURL(clip.url); setClip(null); setText(''); }
    setPhase(ok ? 'idle' : clip ? 'review' : 'idle');
  }

  const head = <p className="small muted">{v.role_title}</p>;
  const alert = msg && <p className={`alert${msg.tone === 'error' ? ' alert--error' : ''}`} role={msg.tone === 'error' ? 'alert' : 'status'} data-testid="iv-msg"><span>{msg.text}</span></p>;

  if (v.state === 'expired') return (<div className="stack-lg" data-testid="iv-expired">{head}<h1 className="d2">This interview link has expired</h1>
    <p>Links work for 7 days. If you still want the role, reply to our email and we will send you a new one.</p>
    <p><Link prefetch={false} className="link" href="/careers">Open roles</Link></p></div>);
  if (v.state === 'submitted' || v.state === 'scored' || !q && v.state === 'started') return (<div className="stack-lg" data-testid="iv-done">{head}
    <h1 className="d2" tabIndex={-1} ref={heading}>Thank you, {v.first_name}. Your interview is done.</h1>
    <p className="lead">Our hiring team will listen to your answers. We will write to you with the next step within two days.</p>
    <p className="small muted">You can close this page.</p></div>);
  if (v.state === 'sent' || v.consent_needed) return (
    <div className="stack-lg" data-testid="iv-intro">
      {head}
      <h1 className="d2">Your interview, {v.first_name}</h1>
      <p className="lead">{v.total} questions, about 10 minutes. Do it now or any time before {new Date(v.expires_at).toLocaleDateString('en-CA', { month: 'long', day: 'numeric', timeZone: 'America/Toronto' })}.</p>
      <ol className="iv-how">
        <li>Each question is shown and read aloud. Press <b>Play the question</b> to hear it again.</li>
        <li>Press <b>Record my answer</b> and speak, as you would on a call. Press <b>Stop</b>, listen back, then <b>Send this answer</b>.</li>
        <li>Prefer to write? <b>Type my answer instead</b> works on every question.</li>
      </ol>
      <p className="small muted">Find a quiet place. Some answers get a short follow-up question. If you leave, open the same link to carry on where you stopped.</p>
      <div className="iv-consent" data-testid="iv-consent">
        <p className="small">{v.consent_text} <Link prefetch={false} className="link" href="/privacy">Privacy policy</Link></p>
        <label className="check"><input type="checkbox" checked={agree} onChange={(e) => setAgree(e.target.checked)} data-testid="iv-agree" /> <span>I agree to the recording</span></label>
      </div>
      {alert}
      <p><button type="button" className="btn btn--primary btn--lg" disabled={!agree || phase === 'sending'} onClick={start} data-testid="iv-start">{phase === 'sending' ? 'Starting' : 'Start the interview'}</button></p>
    </div>);
  if (!q) return null;

  const n = Math.min(v.answered + (q.kind === 'question' ? 1 : 0), v.total);
  return (
    <div className="stack-lg" data-testid="iv-question" data-seq={q.seq} data-kind={q.kind}>
      {head}
      <div className="iv-head">
        <div className="iv-progress" aria-hidden="true"><span style={{ width: `${Math.round(((n - 1) / v.total) * 100)}%` }} /></div>
        <p className="iv-step">{q.kind === 'followup' ? 'A short follow-up' : `Question ${n} of ${v.total}`}</p>
        <h1 className="d3 iv-q" tabIndex={-1} ref={heading} data-testid="iv-text">{q.text}</h1>
      </div>
      <p><button type="button" className="btn btn--ghost btn--sm" onClick={() => speak(q.text)} data-testid="iv-play">Play the question</button></p>
      {alert}
      {!typing && canRecord && (
        <div className="iv-answer" aria-live="polite">
          {phase === 'idle' && <button type="button" className="btn btn--primary btn--lg iv-rec" onClick={record} data-testid="iv-record"><span className="iv-dot" aria-hidden="true" />Record my answer</button>}
          {phase === 'recording' && <>
            <p className="iv-live"><span className="iv-dot is-on" aria-hidden="true" />Recording <span className="iv-time">{fmt(secs)}</span> <span className="small muted">(up to {fmt(MAX_ANSWER_SECONDS)})</span></p>
            <button type="button" className="btn btn--primary btn--lg" onClick={stop} data-testid="iv-stop">Stop</button></>}
          {(phase === 'review' || phase === 'sending') && clip && <>
            <audio controls src={clip.url} className="iv-audio" aria-label="Your answer" />
            <div className="row">
              <button type="button" className="btn btn--primary btn--lg" onClick={send} disabled={phase === 'sending'} data-testid="iv-send">{phase === 'sending' ? 'Sending your answer' : 'Send this answer'}</button>
              <button type="button" className="btn btn--ghost" onClick={again} disabled={phase === 'sending'} data-testid="iv-again">Record again</button>
            </div></>}
        </div>)}
      {(typing || !canRecord) && (
        <div className="stack">
          <label className="field"><span className="label">Your answer</span>
            <textarea className="input" rows={6} value={text} maxLength={4000} onChange={(e) => setText(e.target.value)} data-testid="iv-typed" /></label>
          <p><button type="button" className="btn btn--primary btn--lg" onClick={send} disabled={phase === 'sending'} data-testid="iv-send-typed">{phase === 'sending' ? 'Sending your answer' : 'Send this answer'}</button></p>
        </div>)}
      {canRecord && phase !== 'recording' && phase !== 'sending' && (
        <p className="small"><button type="button" className="link" onClick={() => { setTyping(!typing); setMsg(null); }} data-testid="iv-toggle">{typing ? 'Answer out loud instead' : 'Type my answer instead'}</button></p>)}
    </div>
  );
}
