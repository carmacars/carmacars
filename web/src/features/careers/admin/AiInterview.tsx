import { Badge, Card, Kv, Table, t } from '@/features/admin/ui';
import { AI_STATE_WORDS, RECOMMENDATION_WORDS, type InterviewState, type Recommendation } from '../ai-interview';

// The AI interview on the candidate page (migration 0380): the AI's recommendation, scores with the quote each one rests
// on, the spoken English and the red flags, then every answer in the order asked with its recording and transcript. The
// AI only recommends: the Admin decides with the rubric beside it.
export interface AiAnswer { id: string; seq: number; kind: 'question' | 'followup'; key: string; prompt: string; mode: 'voice' | 'typed'; audio_url: string | null;
  audio_seconds: number | null; transcript: string | null; transcript_state: 'pending' | 'done' | 'failed' }
export interface AiInterviewData {
  id: string; state: InterviewState; sent_at: string; expires_at: string; links_sent: number; consent_at: string | null; consent_text: string | null; started_at: string | null;
  submitted_at: string | null; scored_at: string | null; followups_used: number; interview_score: number | null; recommendation: Recommendation | null; score_model: string | null;
  score_attempts: number; last_error: string | null; purged: boolean; questions_total: number; live_call_at: string | null;
  result: { topics: Array<{ key: string; label: string; weight: number; score: number | null; evidence: string | null }>; english: { level: string | null; score: number | null; notes: string | null };
    red_flags: string[]; summary: string | null; reason: string | null } | null;
  answers: AiAnswer[];
}
type R = Record<string, unknown>;
const LEVEL: Record<string, string> = { fluent: 'Fluent', good: 'Good', basic: 'Basic' };
const tone = (s: InterviewState) => (s === 'scored' ? 'published' : s === 'expired' ? 'closed' : 'draft');
const secs = (n: number | null) => (n ? `${Math.floor(n / 60)}:${String(Math.round(n % 60)).padStart(2, '0')}` : '');

export function AiInterview({ x }: { x: AiInterviewData }) {
  const r = x.result;
  const asked = x.answers.filter((a) => a.kind === 'question').length;
  return (
    <Card title="AI interview" testId="cand-ai" aside={<Badge s={tone(x.state)}>{AI_STATE_WORDS[x.state]}</Badge>}>
      {x.state === 'scored' && x.recommendation && r && (
        <div className="ai-sum" data-testid="cand-ai-rec">
          <p className="ai-rec"><span className="small muted">AI recommends</span> <b>{RECOMMENDATION_WORDS[x.recommendation]}</b></p>
          <p className="small">Interview score <b>{x.interview_score ?? '-'}</b> of 100{r.english.level ? <> · Spoken English <b>{LEVEL[r.english.level] ?? r.english.level}</b>{r.english.score ? ` (${r.english.score} of 5)` : ''}</> : null}</p>
          {r.summary && <p>{r.summary}</p>}
          {r.reason && <p className="small muted">{r.reason}</p>}
          {r.english.notes && <p className="small muted">English: {r.english.notes}</p>}
        </div>)}
      {r && r.red_flags.length > 0 && <div className="alert alert--warn" role="note" data-testid="cand-ai-flags"><span><b>To check:</b> {r.red_flags.join('; ')}</span></div>}
      {x.state === 'submitted' && <p className="small muted" data-testid="cand-ai-waiting">Done {t(x.submitted_at)}. The AI&apos;s scores come by themselves within minutes, or later in the day when today&apos;s AI allowance is used.{x.last_error ? ` Last try: ${x.last_error}` : ''}</p>}
      {(x.state === 'sent' || x.state === 'started') && <p className="small muted">{asked} of {x.questions_total} questions answered. The link works until {t(x.expires_at)}.</p>}
      {x.live_call_at && <p className="small" data-testid="cand-ai-live-sent">Invited to a live call {t(x.live_call_at)}: the booking link went by email.</p>}
      {x.state === 'expired' && !x.live_call_at && <p className="small muted">The link expired {t(x.expires_at)} with {asked} of {x.questions_total} questions answered. Send a new link, or decline.</p>}
      {r && r.topics.length > 0 && <Table<R> testId="cand-ai-topics" caption="The AI's scores" rows={r.topics as unknown as R[]} rowKey={(tp) => String(tp.key)} cols={[
        { key: 'label', label: 'Rubric', className: 'wrap', render: (tp) => <>{String(tp.label)}{tp.weight === 0 ? <span className="cr-sub">noted, not scored</span> : null}</> },
        { key: 'score', label: 'AI score', num: true, render: (tp) => (tp.score ? `${String(tp.score)} / 5` : '-') },
        { key: 'evidence', label: 'From the answers', className: 'wrap', render: (tp) => (tp.evidence ? <q>{String(tp.evidence)}</q> : <span className="muted">no quote</span>) }]} />}
      {x.answers.length > 0 && <>
        <h3 className="d4">Answers and transcript</h3>
        <ol className="ai-answers" data-testid="cand-ai-answers">
          {x.answers.map((a) => (
            <li key={a.id} className={a.kind === 'followup' ? 'is-follow' : undefined}>
              <p className="small muted">{a.kind === 'followup' ? 'Follow-up' : `Question ${x.answers.filter((b) => b.kind === 'question' && b.seq <= a.seq).length}`}{a.mode === 'typed' ? ' · typed' : a.audio_seconds ? ` · ${secs(a.audio_seconds)}` : ''}</p>
              <p className="ai-q">{a.prompt}</p>
              {a.mode === 'voice' && (a.audio_url ? <audio controls preload="none" src={a.audio_url} className="iv-audio" aria-label={`Recording of answer ${a.seq}`} data-testid="cand-ai-audio" /> : <p className="small muted">Recording removed.</p>)}
              <p className="ai-said">{a.transcript ?? <span className="muted">{a.transcript_state === 'failed' ? 'No transcript: listen to the recording.' : 'Transcript on its way.'}</span>}</p>
            </li>))}
        </ol></>}
      <Kv rows={[['Sent', `${t(x.sent_at)}${x.links_sent > 1 ? ` (link ${x.links_sent})` : ''}`], ['Consent to the recording', x.consent_at ? t(x.consent_at) : 'Not yet'],
        ['Follow-ups asked', String(x.followups_used)], ...(x.scored_at ? [['Scored', t(x.scored_at)] as [string, string]] : [])]} />
      <p className="small muted">The AI only recommends. You decide with the rubric; nothing goes to the candidate until you send the decision emails.</p>
    </Card>
  );
}
