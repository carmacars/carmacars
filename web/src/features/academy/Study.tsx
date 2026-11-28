'use client';
import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import Link from '@/components/Link';
import { useRouter } from 'next/navigation';
import { opsAct } from '@/server/actions/ops';
import { ScenePlayer } from './ScenePlayer';
import { LessonVideo } from './LessonVideo';
import { HONEST_NOTE, IntegrityWatch, cdpProbe, markersOf } from './integrity';
import { ownJokeQuip, pct, waitLeft, type QuizFix, type QuizFixResult, type QuizResult, type QuizStart, type QuizVoided, type QuizWait, type SectionView } from './model';

// A section to study (Release 21b, item 9): its lessons, each a scene player, then its quiz. The quiz is graded in the database;
// the pass mark opens the next section of the path. 1154: opening the section starts its reading clock; the quiz opens after the
// section's reading time, is handed out in a random order (questions and options), waits after a failed try (2 minutes since 5070, 1 since 5203) and
// allows a number of tries a day (10 since 5070) (all set in Program settings); a failed try shows which answers were wrong, not the right ones.
// R50 hotfix 2 (5070): a first check below the pass mark is not a try yet: the questions marked wrong (only those) can be
// changed once, and the second check is graded. The database keeps the fix, so reopening the quiz brings it back.
export function Study({ s, base }: { s: SectionView; base: string }) {
  const router = useRouter();
  const [viewed, setViewed] = useState<Record<string, boolean>>(Object.fromEntries(s.lessons.map((l) => [l.id, !!l.viewed])));
  const [wait, setWait] = useState<QuizWait | undefined>(s.quiz);
  const seen = (id: string) => { if (viewed[id]) return; setViewed((v) => ({ ...v, [id]: true })); void opsAct('academy_viewed', { lesson: id }); };
  useEffect(() => {
    if (s.opened_at) return;
    void opsAct<{ quiz: QuizWait }>('academy_opened', { section: s.id }).then((r) => { if (r.ok) setWait(r.data.quiz); });
  }, [s.id, s.opened_at]);
  return (
    <div className="stack-lg">
      {s.lessons.map((l, i) => (
        <section key={l.id} className="pt-card ac-lesson" aria-labelledby={`ac-l-${i}`} data-testid={`lesson-${i}`}>
          <h2 className="d4" id={`ac-l-${i}`}>{i + 1}. {l.title} {viewed[l.id] && <span className="ac-badge ac-badge--ok">Watched</span>}</h2>
          <ScenePlayer lesson={l} onDone={() => seen(l.id)} testId={`player-${i}`} admin={base.startsWith('/admin')} />
          {/* r37 (2301): the lesson as a real video file, to watch or download */}
          <LessonVideo lesson={l.id} title={l.title} scenes={l.scenes} testId={`lesson-video-${i}`} />
        </section>
      ))}
      <Quiz s={s} base={base} wait={wait} setWait={setWait} onPassed={() => router.refresh()} />
    </div>
  );
}

const noop = () => () => {};
const yes = () => true;
const no = () => false;

function Quiz({ s, base, wait, setWait, onPassed }: { s: SectionView; base: string; wait: QuizWait | undefined; setWait: (w: QuizWait | undefined) => void; onPassed: () => void }) {
  const [quiz, setQuiz] = useState<QuizStart | null>(null);
  const [answers, setAnswers] = useState<Record<string, number>>({});
  const [res, setRes] = useState<QuizResult | null>(null);
  const [fix, setFix] = useState<QuizFix | null>(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const [now, setNow] = useState(() => Date.now());
  // R51 (5199, REQ-130): what the page sees while the quiz is open; sent with each submit, voided by the database on a signal
  const watch = useRef<IntegrityWatch | null>(null);
  const [voided, setVoided] = useState('');
  // r50 hotfix 2: the countdown starts once the page is in the browser; the server's second and the browser's differed (#418)
  const hydrated = useSyncExternalStore(noop, yes, no);
  const left = hydrated && wait && !wait.ok ? waitLeft(wait.until, now) : '';
  useEffect(() => {
    if (!wait || wait.ok) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [wait]);
  const ready = !wait || wait.ok || !left;
  const start = async () => {
    setBusy(true); setErr('');
    const r = await opsAct<QuizStart>('academy_quiz_start', { section: s.id });
    setBusy(false);
    if (!r.ok) { setErr(r.message); return; }
    setQuiz(r.data); setRes(null); setVoided('');
    setFix(r.data.fix ?? null); setAnswers(r.data.fix?.given ?? {});
    // a fix of the same quiz keeps counting from the first try
    if (!r.data.fix || !watch.current) {
      let wd = false; try { wd = navigator.webdriver === true; } catch { /* none */ }
      // the devtools protocol probe logs one empty error at debug level (integrity.ts cdpProbe)
      // eslint-disable-next-line no-console
      watch.current = new IntegrityWatch({ webdriver: wd, markers: markersOf(window as unknown as Record<string, unknown>, document as unknown as Record<string, unknown>), cdp: cdpProbe((e) => console.debug(e)) }, Date.now());
    }
  };
  // the page lost focus or was hidden while the quiz is open
  useEffect(() => {
    if (!quiz || res) return;
    const away = () => watch.current?.leave();
    const back = () => { if (!document.hidden && document.hasFocus()) watch.current?.back(); };
    const vis = () => (document.hidden ? away() : back());
    window.addEventListener('blur', away); window.addEventListener('focus', back); document.addEventListener('visibilitychange', vis);
    return () => { window.removeEventListener('blur', away); window.removeEventListener('focus', back); document.removeEventListener('visibilitychange', vis); };
  }, [quiz, res]);
  const qs = quiz?.questions ?? [];
  const all = qs.length > 0 && qs.every((q) => answers[q.id] !== undefined);
  const submit = async () => {
    if (!all) { setErr('Answer every question first.'); return; }
    setBusy(true); setErr('');
    const r = await opsAct<QuizResult | QuizFixResult | QuizVoided>('academy_quiz_submit', { section: s.id, answers, integrity: watch.current?.report() ?? null });
    setBusy(false);
    if (!r.ok) { setErr(r.message); return; }
    if ('voided' in r.data) { watch.current = null; setFix(null); setQuiz(null); setAnswers({}); setWait(r.data.quiz); setNow(Date.now()); setVoided(r.data.message ?? 'This attempt was voided.'); return; }
    if ('fix' in r.data && r.data.fix) { setFix({ wrong: r.data.wrong, given: answers }); return; }
    const g = r.data as QuizResult;
    watch.current = null;
    setFix(null); setRes(g); setWait(g.quiz); setNow(Date.now());
    if (g.passed) onPassed();
  };
  const by = new Map(res?.results.map((x) => [x.id, x]) ?? []);
  const toFix = new Set(fix?.wrong ?? []);
  const count = s.question_count ?? s.questions.length;
  return (
    <section className="pt-card stack ac-quiz" aria-labelledby="ac-quiz" data-testid="quiz">
      <h2 className="d4" id="ac-quiz">Quiz: {s.title}</h2>
      <p className="small muted">{count} questions. Pass mark {pct(s.pass_bps)}.{s.passed ? ` Passed (best ${pct(s.best_bps)}).` : ''}{quiz?.tries_left !== undefined ? ` ${quiz.tries_left} ${quiz.tries_left === 1 ? 'try' : 'tries'} left today.` : ''}</p>
      {!quiz && (ready
        ? <div><button type="button" className="btn btn--primary" onClick={() => void start()} disabled={busy} data-testid="quiz-start">{busy ? 'Starting' : 'Start the quiz'}</button></div>
        : <p className="alert alert--warn" role="status" data-testid="quiz-wait"><span>{wait?.message}</span>{left ? <span> Opens in {left}.</span> : null}</p>)}
      {quiz && fix && !res && (
        <div className="alert alert--warn" role="status" data-testid="quiz-fix">
          <span className="alert__title">Fix the ones marked wrong</span>
          <span>{fix.wrong.length} of {qs.length} {fix.wrong.length === 1 ? 'answer is' : 'answers are'} wrong. You can change only those, once. The next check counts.</span>
        </div>)}
      <p className="small ac-honest" data-testid="quiz-honest">{HONEST_NOTE}</p>
      {voided && <p className="alert alert--warn" role="alert" data-testid="quiz-voided"><span className="alert__title">Attempt voided</span><span>{voided}</span></p>}
      {quiz && <form className="stack ac-guarded" noValidate onSubmit={(e) => { e.preventDefault(); void submit(); }}
        onPasteCapture={(e) => { e.preventDefault(); watch.current?.paste(); }} onCopyCapture={(e) => { e.preventDefault(); watch.current?.copy(); }} onCutCapture={(e) => { e.preventDefault(); watch.current?.copy(); }}
        onContextMenu={(e) => e.preventDefault()} onPointerMoveCapture={(e) => watch.current?.pointerMove(e)} onPointerDownCapture={(e) => watch.current?.pointerDown(e.nativeEvent)}
        onClickCapture={(e) => watch.current?.input(e.nativeEvent)} onKeyDownCapture={(e) => watch.current?.input(e.nativeEvent)} onChangeCapture={(e) => watch.current?.input(e.nativeEvent)}>
        {qs.map((q, qi) => {
          const r = by.get(q.id);
          return (
            <fieldset key={q.id} data-testid={`q-${qi}`} className={!res && fix ? (toFix.has(q.id) ? 'ac-fix' : 'ac-fix-ok') : undefined} data-fix={!res && fix ? (toFix.has(q.id) ? 'wrong' : 'right') : undefined}>
              <legend>{qi + 1}. {q.prompt}</legend>
              <p className="small muted ac-honest" data-testid={`q-${qi}-honest`}>{HONEST_NOTE}</p>
              {!res && fix && (toFix.has(q.id)
                ? <p className="small is-wrong" data-testid={`q-${qi}-fix`}>Marked wrong: choose again.</p>
                : <p className="small muted">Right. Kept as you answered.</p>)}
              {q.options.map((o, oi) => {
                const k = q.keys[oi] ?? oi;
                return (
                  <label key={oi} className={`check${r && r.answer !== null && k === r.answer ? ' is-right' : r && k === r.given && !r.right ? ' is-wrong' : ''}`}>
                    <input type="radio" name={`q-${q.id}`} checked={answers[q.id] === k} disabled={!!res || (!!fix && !toFix.has(q.id))} onChange={() => { watch.current?.pick(q.id, Date.now()); setAnswers((a) => ({ ...a, [q.id]: k })); }} data-testid={`q-${qi}-${oi}`} />
                    <span>{o}{r && r.answer !== null && k === r.answer ? ' (right answer)' : ''}</span>
                  </label>
                );
              })}
              {r && (() => {
                // 4720: some questions carry their own funny wrong option (q.joke: where it is shown); picking it is simply wrong, with a playful line
                const shown = r.given === null ? -1 : q.keys.indexOf(r.given);
                const quip = shown >= 0 && q.joke === shown ? ownJokeQuip(q.options[shown]) : '';
                return <p className={`small ${r.right ? 'is-right' : 'is-wrong'}`} data-testid={quip ? `q-${qi}-joke` : undefined}>{r.right ? 'Right.' : 'Not quite.'}{quip ? ` ${quip}` : ''} {r.explain}</p>;
              })()}
            </fieldset>
          );
        })}
        {!res && <button className="btn btn--primary" type="submit" disabled={busy} data-testid="quiz-submit">{busy ? 'Checking' : fix ? 'Check my fixes' : 'Check my answers'}</button>}
      </form>}
      {err && <p className="error" role="alert">{err}</p>}
      {res && (
        <div className={`alert ${res.passed ? 'alert--ok' : 'alert--warn'}`} role="status" data-testid="quiz-result">
          <span className="alert__title">{res.passed ? 'Passed' : 'Not passed yet'}: {res.correct} of {res.total} ({pct(res.score_bps)})</span>
          <span>{res.passed ? (s.next ? 'The next section is open.' : 'You finished this path.') : `You need ${pct(res.pass_bps)}. Go over the lessons again. ${res.quiz?.message ?? ''}`}</span>
          <span className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }}>
            {/* 5203 (REQ-134): one press starts the next try once the wait is over (it was Try again later, then Start the quiz) */}
            {!res.passed && <button type="button" className="btn btn--sm btn--primary" disabled={busy || !ready} aria-describedby="quiz-retry-hint" onClick={() => { setRes(null); setFix(null); setQuiz(null); setAnswers({}); void start(); }} data-testid="quiz-retry">{ready ? 'Try again' : `Try again in ${left}`}</button>}
            {!res.passed && <span id="quiz-retry-hint" className="small muted">{ready ? 'Go over the lessons first.' : 'Wait for the minute to pass, then press Try again.'}</span>}
            {res.passed && s.next && <Link prefetch={false} className="btn btn--sm btn--primary" href={`${base}/${s.path}/${s.next}`} data-testid="quiz-next">Next section</Link>}
            <Link prefetch={false} className="btn btn--sm btn--quiet" href={base}>Back to my paths</Link>
          </span>
        </div>
      )}
    </section>
  );
}
