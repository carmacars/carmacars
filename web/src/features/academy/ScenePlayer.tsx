'use client';
import { useCallback, useEffect, useRef, useState } from 'react';
import { pickVoice, progress, sceneMs, words, type Lesson, type Scene, type Visual } from './model';

// A lesson as a video made in the browser (Release 21b, item 9): each scene is HTML and CSS with motion (src/features/academy/
// academy.css), its words on screen as captions, and narrated by the browser's own voice (Web Speech API, speechSynthesis) in
// English. No English voice, or the voice turned off: captions only, each scene timed by its reading length. Nothing is
// downloaded or stored. Play, pause, replay, the previous and next scene, and the speed; Space and the arrow keys work when the
// player has the focus. onDone runs once the last scene has played.
const SPEEDS = [0.75, 1, 1.25, 1.5] as const;

export function ScenePlayer({ lesson, onDone, testId = 'player' }: { lesson: Lesson; onDone?: () => void; testId?: string }) {
  const n = lesson.scenes.length;
  const [idx, setIdx] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [started, setStarted] = useState(false);
  const [done, setDone] = useState(false);
  const [within, setWithin] = useState(0);
  const [speed, setSpeed] = useState<number>(1);
  const [voiceOn, setVoiceOn] = useState(true);
  const [voice, setVoice] = useState<SpeechSynthesisVoice | null>(null);
  const [voiceKnown, setVoiceKnown] = useState(false);
  const [take, setTake] = useState(0);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const tick = useRef<ReturnType<typeof setInterval> | undefined>(undefined);
  const run = useRef(0);
  const doneFired = useRef(false);

  // the browser's voices arrive late on some browsers: wait for them a moment, else captions only
  useEffect(() => {
    if (typeof window === 'undefined' || !('speechSynthesis' in window)) { const t = setTimeout(() => setVoiceKnown(true), 0); return () => clearTimeout(t); }
    const synth = window.speechSynthesis;
    const load = () => { const v = pickVoice(synth.getVoices()); if (v) { setVoice(v); setVoiceKnown(true); } };
    const t0 = setTimeout(load, 0);
    synth.addEventListener?.('voiceschanged', load);
    const t = setTimeout(() => setVoiceKnown(true), 1500);
    return () => { clearTimeout(t0); clearTimeout(t); synth.removeEventListener?.('voiceschanged', load); synth.cancel(); };
  }, []);

  const stop = useCallback(() => {
    run.current += 1;
    clearTimeout(timer.current); clearInterval(tick.current);
    if (typeof window !== 'undefined' && 'speechSynthesis' in window) window.speechSynthesis.cancel();
  }, []);
  useEffect(() => stop, [stop]);

  const finish = useCallback(() => {
    stop(); setPlaying(false); setDone(true); setWithin(1);
    if (!doneFired.current) { doneFired.current = true; onDone?.(); }
  }, [stop, onDone]);

  const playRef = useRef<(i: number) => void>(() => undefined);
  const play = useCallback((i: number) => {
    stop();
    const me = run.current;
    const scene: Scene | undefined = lesson.scenes[i];
    if (!scene) { finish(); return; }
    setIdx(i); setWithin(0); setPlaying(true); setStarted(true); setDone(false); setTake((t) => t + 1);
    const est = sceneMs(scene, speed);
    const t0 = Date.now();
    tick.current = setInterval(() => { if (run.current === me) setWithin(Math.min(0.98, (Date.now() - t0) / est)); }, 200);
    const next = () => { if (run.current !== me) return; if (i + 1 < n) playRef.current(i + 1); else finish(); };
    const synth = typeof window !== 'undefined' && 'speechSynthesis' in window ? window.speechSynthesis : null;
    if (voiceOn && voice && synth) {
      const u = new SpeechSynthesisUtterance(words(scene));
      u.voice = voice; u.lang = voice.lang; u.rate = speed;
      u.onend = () => { timer.current = setTimeout(next, 350); };
      u.onerror = () => { timer.current = setTimeout(next, 350); };
      synth.speak(u);
      // a voice that never ends (a browser quirk): move on after twice the reading time
      timer.current = setTimeout(next, est * 2 + 2000);
    } else {
      timer.current = setTimeout(next, est);
    }
  }, [stop, finish, lesson.scenes, n, speed, voiceOn, voice]);
  // a new speed or the voice turned on or off restarts the scene playing, with the new setting
  const restart = useRef(-1);
  useEffect(() => {
    playRef.current = play;
    if (restart.current < 0) return;
    const i = restart.current; restart.current = -1;
    const t = setTimeout(() => playRef.current(i), 0);
    return () => clearTimeout(t);
  }, [play]);

  const pause = () => { stop(); setPlaying(false); };
  const toggle = () => (playing ? pause() : play(done ? 0 : idx));
  const go = (i: number) => { const j = Math.max(0, Math.min(n - 1, i)); if (playing) play(j); else { stop(); setIdx(j); setWithin(0); setStarted(true); setDone(false); } };
  // stepping by hand past the last scene counts as watched
  const nextScene = () => { if (idx + 1 < n) go(idx + 1); else finish(); };

  const scene = lesson.scenes[idx]!;
  const pc = Math.round((done ? 1 : progress(idx, within, n)) * 100);
  const captionsOnly = voiceKnown && (!voice || !voiceOn);
  return (
    <div className="ac-player" data-testid={testId} tabIndex={0} role="region" aria-label={`Lesson video: ${lesson.title}`}
      onKeyDown={(e) => {
        if (e.target !== e.currentTarget) return;
        if (e.key === ' ' || e.key === 'k') { e.preventDefault(); toggle(); }
        else if (e.key === 'ArrowRight') { e.preventDefault(); nextScene(); }
        else if (e.key === 'ArrowLeft') { e.preventDefault(); go(idx - 1); }
      }}>
      <div className={`ac-stage${playing ? ' is-playing' : ''}`} aria-hidden={!started}>
        {!started ? (
          <div className="ac-cover"><p className="ac-cover__kicker">Lesson</p><p className="ac-cover__title">{lesson.title}</p>
            <p className="ac-cover__meta">{n} scenes · about {Math.max(1, Math.round(lesson.scenes.reduce((s, x) => s + sceneMs(x), 0) / 60000))} min</p></div>
        ) : <SceneView key={`${idx}-${take}`} scene={scene} />}
      </div>
      <p className="ac-caption" data-testid={`${testId}-caption`}>{started ? words(scene) : 'Press Play. The lesson is narrated by your browser\'s voice, with captions.'}</p>
      <div className="ac-bar" role="progressbar" aria-label="Lesson progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={pc} data-testid={`${testId}-progress`}>
        <span style={{ inlineSize: `${pc}%` }} />
      </div>
      <div className="ac-controls">
        <button type="button" className="btn btn--sm btn--primary" onClick={toggle} data-testid={`${testId}-play`} aria-label={playing ? 'Pause' : done ? 'Replay' : started ? 'Resume' : 'Play'}>{playing ? 'Pause' : done ? 'Replay' : started ? 'Resume' : 'Play'}</button>
        <button type="button" className="btn btn--sm btn--quiet" onClick={() => go(idx - 1)} disabled={idx === 0} aria-label="Previous scene">Back</button>
        <button type="button" className="btn btn--sm btn--quiet" onClick={nextScene} aria-label="Next scene" data-testid={`${testId}-next`}>Next</button>
        <button type="button" className="btn btn--sm btn--quiet" onClick={() => play(0)} data-testid={`${testId}-replay`}>Replay</button>
        <label className="ac-speed small">Speed <select className="select select--sm" value={speed} onChange={(e) => { if (playing) restart.current = idx; setSpeed(Number(e.target.value)); }} data-testid={`${testId}-speed`}>
          {SPEEDS.map((s) => <option key={s} value={s}>{s}x</option>)}</select></label>
        {voice && <button type="button" className="btn btn--sm btn--quiet" aria-pressed={voiceOn} onClick={() => { if (playing) restart.current = idx; setVoiceOn((v) => !v); }}>{voiceOn ? 'Voice on' : 'Voice off'}</button>}
        <span className="small muted" data-testid={`${testId}-scene`}>Scene {idx + 1} of {n}{captionsOnly ? ' · captions only' : ''}</span>
      </div>
    </div>
  );
}

function SceneView({ scene }: { scene: Scene }) {
  const v: Visual = scene.visual;
  const d = (i: number) => ({ ['--i' as string]: i }) as React.CSSProperties;
  return (
    <div className={`ac-scene ac-scene--${v.kind}`}>
      <p className="ac-scene__kicker">{scene.caption}</p>
      {v.kind === 'title' && <><p className="ac-scene__big">{v.heading}</p>{v.text && <p className="ac-scene__sub">{v.text}</p>}</>}
      {v.kind === 'rule' && <div className={`ac-rule ac-rule--${v.tone ?? 'ok'}`}><p className="ac-scene__head">{v.heading}</p><p>{v.text}</p></div>}
      {(v.kind === 'list' || v.kind === 'steps') && <><p className="ac-scene__head">{v.heading}</p>
        {v.kind === 'steps' ? <ol className="ac-items ac-items--steps">{v.items.map((x, i) => <li key={i} style={d(i)}>{x}</li>)}</ol>
          : <ul className="ac-items">{v.items.map((x, i) => <li key={i} style={d(i)}>{x}</li>)}</ul>}</>}
      {v.kind === 'money' && <><p className="ac-scene__head">{v.heading}</p>
        <dl className="ac-money">{v.rows.map(([k, x], i) => <div key={i} style={d(i)}><dt>{k}</dt><dd>{x}</dd></div>)}
          {v.total && <div className="ac-money__total" style={d(v.rows.length)}><dt>{v.total[0]}</dt><dd>{v.total[1]}</dd></div>}</dl></>}
      {v.kind === 'chat' && <div className="ac-chat">{v.lines.map((l, i) => <p key={i} className={`ac-bubble ac-bubble--${l.who === 'you' ? 'you' : 'them'}`} style={d(i)}><span className="ac-bubble__who">{l.who === 'you' ? 'You' : l.who.charAt(0).toUpperCase() + l.who.slice(1)}</span>{l.text}</p>)}</div>}
    </div>
  );
}
