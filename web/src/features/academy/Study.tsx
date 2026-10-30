'use client';
import { useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { opsAct } from '@/server/actions/ops';
import { ScenePlayer } from './ScenePlayer';
import { pct, type QuizResult, type SectionView } from './model';

// A section to study (Release 21b, item 9): its lessons, each a scene player, then its quiz. The quiz is graded in the database;
// the pass mark opens the next section of the path. Retries are allowed.
export function Study({ s, base }: { s: SectionView; base: string }) {
  const router = useRouter();
  const [viewed, setViewed] = useState<Record<string, boolean>>(Object.fromEntries(s.lessons.map((l) => [l.id, !!l.viewed])));
  const seen = (id: string) => { if (viewed[id]) return; setViewed((v) => ({ ...v, [id]: true })); void opsAct('academy_viewed', { lesson: id }); };
  return (
    <div className="stack-lg">
      {s.lessons.map((l, i) => (
        <section key={l.id} className="pt-card ac-lesson" aria-labelledby={`ac-l-${i}`} data-testid={`lesson-${i}`}>
          <h2 className="d4" id={`ac-l-${i}`}>{i + 1}. {l.title} {viewed[l.id] && <span className="ac-badge ac-badge--ok">Watched</span>}</h2>
          <ScenePlayer lesson={l} onDone={() => seen(l.id)} testId={`player-${i}`} />
        </section>
      ))}
      <Quiz s={s} base={base} onPassed={() => router.refresh()} />
    </div>
  );
}

function Quiz({ s, base, onPassed }: { s: SectionView; base: string; onPassed: () => void }) {
  const [answers, setAnswers] = useState<Record<string, number>>({});
  const [res, setRes] = useState<QuizResult | null>(null);
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const all = s.questions.every((q) => answers[q.id] !== undefined);
  const submit = async () => {
    if (!all) { setErr('Answer every question first.'); return; }
    setBusy(true); setErr('');
    const r = await opsAct<QuizResult>('academy_quiz_submit', { section: s.id, answers });
    setBusy(false);
    if (!r.ok) { setErr(r.message); return; }
    setRes(r.data);
    if (r.data.passed) onPassed();
  };
  const by = new Map(res?.results.map((x) => [x.id, x]) ?? []);
  return (
    <section className="pt-card stack ac-quiz" aria-labelledby="ac-quiz" data-testid="quiz">
      <h2 className="d4" id="ac-quiz">Quiz: {s.title}</h2>
      <p className="small muted">{s.questions.length} questions. Pass mark {pct(s.pass_bps)}. You can try again as often as you need.{s.passed ? ` Passed (best ${pct(s.best_bps)}).` : ''}</p>
      <form className="stack" noValidate onSubmit={(e) => { e.preventDefault(); void submit(); }}>
        {s.questions.map((q, qi) => {
          const r = by.get(q.id);
          return (
            <fieldset key={q.id} data-testid={`q-${qi}`}>
              <legend>{qi + 1}. {q.prompt}</legend>
              {q.options.map((o, oi) => (
                <label key={oi} className={`check${r && oi === r.answer ? ' is-right' : r && oi === r.given && !r.right ? ' is-wrong' : ''}`}>
                  <input type="radio" name={`q-${q.id}`} checked={answers[q.id] === oi} disabled={!!res} onChange={() => setAnswers((a) => ({ ...a, [q.id]: oi }))} data-testid={`q-${qi}-${oi}`} />
                  <span>{o}{r && oi === r.answer ? ' (right answer)' : ''}</span>
                </label>
              ))}
              {r && <p className={`small ${r.right ? 'is-right' : 'is-wrong'}`}>{r.right ? 'Right.' : 'Not quite.'} {r.explain}</p>}
            </fieldset>
          );
        })}
        {err && <p className="error" role="alert">{err}</p>}
        {!res && <button className="btn btn--primary" type="submit" disabled={busy} data-testid="quiz-submit">{busy ? 'Checking' : 'Check my answers'}</button>}
      </form>
      {res && (
        <div className={`alert ${res.passed ? 'alert--ok' : 'alert--warn'}`} role="status" data-testid="quiz-result">
          <span className="alert__title">{res.passed ? 'Passed' : 'Not passed yet'}: {res.correct} of {res.total} ({pct(res.score_bps)})</span>
          <span>{res.passed ? (s.next ? 'The next section is open.' : 'You finished this path.') : `You need ${pct(res.pass_bps)}. Watch the lessons again and retry.`}</span>
          <span className="row" style={{ gap: 'var(--s-2)', flexWrap: 'wrap' }}>
            {!res.passed && <button type="button" className="btn btn--sm btn--primary" onClick={() => { setRes(null); setAnswers({}); }} data-testid="quiz-retry">Try again</button>}
            {res.passed && s.next && <Link prefetch={false} className="btn btn--sm btn--primary" href={`${base}/${s.path}/${s.next}`} data-testid="quiz-next">Next section</Link>}
            <Link prefetch={false} className="btn btn--sm btn--quiet" href={base}>Back to my paths</Link>
          </span>
        </div>
      )}
    </section>
  );
}
