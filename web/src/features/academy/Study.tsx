'use client';
import { useEffect, useState } from 'react';
import Link from '@/components/Link';
import { useRouter } from 'next/navigation';
import { opsAct } from '@/server/actions/ops';
import { ScenePlayer } from './ScenePlayer';
import { pct, waitLeft, type QuizResult, type QuizStart, type QuizWait, type SectionView } from './model';

// A section to study (Release 21b, item 9): its lessons, each a scene player, then its quiz. The quiz is graded in the database;
// the pass mark opens the next section of the path. 1154: opening the section starts its reading clock; the quiz opens after the
// section's reading time, is handed out in a random order (questions and options), waits 30 minutes after a failed try and
// allows 3 tries a day (all set in Program settings); a failed try shows which answers were wrong, not the right ones.
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
          <ScenePlayer lesson={l} onDone={() => seen(l.id)} testId={`player-${i}`} />
        </section>
      ))}
      <Quiz s={s} base={base} wait={wait} setWait={setWait} onPassed={() => router.refresh()} />
    </div>
  );
}

function Quiz({ s, base, wait, setWait, onPassed }: { s: SectionView; base: string; wait: QuizWait | undefined; setWait: (w: QuizWait | undefined) => void; onPassed: () => void }) {
  const [quiz, setQuiz] = useState<QuizStart | null>(null);
  const [answers, setAnswers] = useState<Record<string, number>>({});
  const [res, setRes] = useState<QuizResult | null>(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const [now, setNow] = useState(() => Date.now());
  const left = wait && !wait.ok ? waitLeft(wait.until, now) : '';
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
    setQuiz(r.data); setAnswers({}); setRes(null);
  };
  const qs = quiz?.questions ?? [];
  const all = qs.length > 0 && qs.every((q) => answers[q.id] !== undefined);
  const submit = async () => {
    if (!all) { setErr('Answer every question first.'); return; }
    setBusy(true); setErr('');
    const r = await opsAct<QuizResult>('academy_quiz_submit', { section: s.id, answers });
    setBusy(false);
    if (!r.ok) { setErr(r.message); return; }
    setRes(r.data); setWait(r.data.quiz); setNow(Date.now());
    if (r.data.passed) onPassed();
  };
  const by = new Map(res?.results.map((x) => [x.id, x]) ?? []);
  const count = s.question_count ?? s.questions.length;
  return (
    <section className="pt-card stack ac-quiz" aria-labelledby="ac-quiz" data-testid="quiz">
      <h2 className="d4" id="ac-quiz">Quiz: {s.title}</h2>
      <p className="small muted">{count} questions. Pass mark {pct(s.pass_bps)}.{s.passed ? ` Passed (best ${pct(s.best_bps)}).` : ''}{quiz?.tries_left !== undefined ? ` ${quiz.tries_left} ${quiz.tries_left === 1 ? 'try' : 'tries'} left today.` : ''}</p>
      {!quiz && (ready
        ? <div><button type="button" className="btn btn--primary" onClick={() => void start()} disabled={busy} data-testid="quiz-start">{busy ? 'Starting' : 'Start the quiz'}</button></div>
        : <p className="alert alert--warn" role="status" data-testid="quiz-wait"><span>{wait?.message}</span>{left ? <span> Opens in {left}.</span> : null}</p>)}
      {quiz && <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); void submit(); }}>
        {qs.map((q, qi) => {
          const r = by.get(q.id);
          return (
            <fieldset key={q.id} data-testid={`q-${qi}`}>
              <legend>{qi + 1}. {q.prompt}</legend>
              {q.options.map((o, oi) => {
                const k = q.keys[oi] ?? oi;
                return (
                  <label key={oi} className={`check${r && r.answer !== null && k === r.answer ? ' is-right' : r && k === r.given && !r.right ? ' is-wrong' : ''}`}>
                    <input type="radio" name={`q-${q.id}`} checked={answers[q.id] === k} disabled={!!res} onChange={() => setAnswers((a) => ({ ...a, [q.id]: k }))} data-testid={`q-${qi}-${oi}`} />
                    <span>{o}{r && r.answer !== null && k === r.answer ? ' (right answer)' : ''}</span>
                  </label>
                );
              })}
              {r && <p className={`small ${r.right ? 'is-right' : 'is-wrong'}`}>{r.right ? 'Right.' : 'Not quite.'} {r.explain}</p>}
            </fieldset>
          );
        })}
        {!res && <button className="btn btn--primary" type="submit" disabled={busy} data-testid="quiz-submit">{busy ? 'Checking' : 'Check my answers'}</button>}
      </form>}
      {err && <p className="error" role="alert">{err}</p>}
      {res && (
        <div className={`alert ${res.passed ? 'alert--ok' : 'alert--warn'}`} role="status" data-testid="quiz-result">
          <span className="alert__title">{res.passed ? 'Passed' : 'Not passed yet'}: {res.correct} of {res.total} ({pct(res.score_bps)})</span>
          <span>{res.passed ? (s.next ? 'The next section is open.' : 'You finished this path.') : `You need ${pct(res.pass_bps)}. Go over the lessons again. ${res.quiz?.message ?? ''}`}</span>
          <span className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }}>
            {!res.passed && <button type="button" className="btn btn--sm btn--primary" onClick={() => { setRes(null); setQuiz(null); setAnswers({}); }} data-testid="quiz-retry">Try again later</button>}
            {res.passed && s.next && <Link prefetch={false} className="btn btn--sm btn--primary" href={`${base}/${s.path}/${s.next}`} data-testid="quiz-next">Next section</Link>}
            <Link prefetch={false} className="btn btn--sm btn--quiet" href={base}>Back to my paths</Link>
          </span>
        </div>
      )}
    </section>
  );
}
