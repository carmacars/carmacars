import 'server-only';
import { rpc } from '@/lib/db/repo';
import type { Json } from '@/lib/db/types';
import { textGenerator } from '@/integrations/llm';
import { transcriber } from '@/integrations/transcribe';
import {
  audioExt, DETAILED_WORDS, FOLLOWUP_SCHEMA, FOLLOWUP_SYSTEM, followupPrompt, MAX_AUDIO_BYTES, MAX_VIDEO_BYTES, pickFollowup, SCORE_SCHEMA, scorePrompt, scoreSystem, videoExt, words,
  type InterviewView, type ScoreInput, type Topic
} from '@/features/careers/ai-interview';

// The AI interview (migration 0380), server side. An answer: the audio is kept in private storage first, then recorded
// in order, then turned into text (Workers AI Whisper, live share of the day's allowance), then a vague answer to a
// question may get one follow-up (at most two an interview). Whatever the model cannot do now (the allowance used, an
// error) never stops the candidate: the answer is kept and the interviews job finishes it. The scores come from the job.
const SR = { role: 'service_role' as const };
export const TOKEN = /^[0-9a-f]{64}$/;
type Answered = InterviewView & { answer_id?: string; kind?: string; question?: string; followups_left?: number; transcribe_model?: string; repeat?: boolean };
type Fail = { ok: false; error: string; next?: unknown };

export async function interviewView(token: string): Promise<InterviewView | Fail | null> {
  if (!TOKEN.test(token)) return null;
  return (await rpc('server_ai_interview', { p_token: token }, SR).catch(() => null)) as unknown as InterviewView | Fail | null;
}

export async function startInterview(token: string): Promise<InterviewView | Fail> {
  return (await rpc('server_ai_interview_start', { p_token: token, p: { consent: true } }, SR)) as unknown as InterviewView | Fail;
}

export interface AnswerInput {
  seq: number; mode: 'voice' | 'typed' | 'none'; text?: string; audio?: Uint8Array; type?: string; seconds?: number;
  /** 0585: the answer's video and its audio track, uploaded by the browser to the keys prepareUpload gave */
  audio_key?: string; video_key?: string; video_type?: string; video_bytes?: number; retakes_used?: number;
}

// 0585: the browser uploads an answer's video and its audio track straight to private storage (signed links, a quarter of
// an hour), then sends the answer with the two keys. The keys are bound to this interview and this question.
const KEY_RE = (id: string) => new RegExp(`^hiring/interviews/${id}/[0-9]+-[a-z0-9]+(-v)?\\.(webm|mp4|m4a|ogg)$`);
export async function prepareUpload(token: string, seq: number, videoType: string, audioType: string):
  Promise<{ ok: true; video: { key: string; url: string; headers: Record<string, string> }; audio: { key: string; url: string; headers: Record<string, string> } } | { ok: false; status: number; message: string }> {
  const view = await interviewView(token);
  if (!view || !view.ok) return { ok: false, status: 404, message: ERRORS.not_found! };
  if (!view.next || view.next.seq !== seq) return { ok: false, status: 409, message: ERRORS.order! };
  const vx = videoExt(videoType); const ax = audioExt(audioType);
  if (!vx || !ax) return { ok: false, status: 400, message: ERRORS.invalid! };
  const id = crypto.randomUUID().replace(/-/g, '').slice(0, 10);
  const base = `hiring/interviews/${view.id}/${seq}-${id}`;
  const { storage } = await import('@/integrations/storage');
  const st = await storage();
  const vt = videoType.split(';')[0]!.trim(); const at = audioType.split(';')[0]!.trim();
  const v = await st.signedUploadUrl('documents', `${base}-v.${vx}`, vt, 900);
  const a = await st.signedUploadUrl('documents', `${base}.${ax}`, at, 900);
  return { ok: true, video: { key: `${base}-v.${vx}`, ...v }, audio: { key: `${base}.${ax}`, ...a } };
}
export type AnswerResult = { ok: true; view: InterviewView; heard: 'typed' | 'transcribed' | 'later' } | { ok: false; status: number; message: string };
const ERRORS: Record<string, string> = {
  consent: 'Please agree to the recording first.', order: 'This question was answered already. The page has the next one.', closed: 'This interview is closed.',
  empty: 'Type your answer first.', invalid: 'We could not keep that recording. Please try again, or type your answer.', not_found: 'This link is not valid.'
};

export async function answerQuestion(token: string, i: AnswerInput): Promise<AnswerResult> {
  const view = await interviewView(token);
  if (!view || !view.ok) return { ok: false, status: 404, message: ERRORS[(view as Fail | null)?.error ?? 'not_found'] ?? ERRORS.not_found! };
  let key: string | null = null;
  let ext: string | null = null;
  if (i.mode === 'voice' && i.audio_key) {
    // 0585: uploaded already: both files must be this interview's and be there; the audio track is read for the transcript
    if (!KEY_RE(view.id).test(i.audio_key) || (i.video_key && !KEY_RE(view.id).test(i.video_key))) return { ok: false, status: 400, message: ERRORS.invalid! };
    if (!view.next || view.next.seq !== i.seq || !i.audio_key.startsWith(`hiring/interviews/${view.id}/${i.seq}-`)) return { ok: false, status: 409, message: ERRORS.order! };
    if ((i.video_bytes ?? 0) > MAX_VIDEO_BYTES) return { ok: false, status: 400, message: ERRORS.invalid! };
    const { storage } = await import('@/integrations/storage');
    const got = await (await storage()).get('documents', i.audio_key);
    if (!got || got.byteLength < 200 || got.byteLength > MAX_AUDIO_BYTES) return { ok: false, status: 400, message: 'The recording did not arrive. Please try again.' };
    i = { ...i, audio: got };
    key = i.audio_key ?? null;
  } else if (i.mode === 'voice') {
    ext = audioExt(i.type ?? '');
    if (!ext || !i.audio || i.audio.byteLength < 200 || i.audio.byteLength > MAX_AUDIO_BYTES) return { ok: false, status: 400, message: ERRORS.invalid! };
    if (!view.next || view.next.seq !== i.seq) return { ok: false, status: 409, message: ERRORS.order! };
    // the audio is kept first: an answer is never recorded without its file
    key = `hiring/interviews/${view.id}/${i.seq}-${crypto.randomUUID().replace(/-/g, '').slice(0, 10)}.${ext}`;
    const { storage } = await import('@/integrations/storage');
    await (await storage()).put('documents', key, i.audio, (i.type ?? '').split(';')[0]!.trim() || 'application/octet-stream');
  }
  const r = (await rpc('server_ai_interview_answer', { p_token: token, p: { seq: i.seq, mode: i.mode, text: i.text ?? null, audio_key: key, audio_type: i.type ?? null,
    audio_bytes: i.audio?.byteLength ?? null, audio_seconds: i.seconds ?? null, video_key: i.video_key ?? null, video_type: i.video_type ?? null,
    video_bytes: i.video_bytes ?? null, retakes_used: i.retakes_used ?? 0 } as unknown as Json }, SR)) as unknown as Answered | Fail;
  if (!r.ok) return { ok: false, status: r.error === 'order' ? 409 : 400, message: ERRORS[r.error] ?? 'We could not keep that answer. Please try again.' };
  if (r.repeat) return { ok: true, view: r, heard: 'typed' };
  let said = i.mode === 'typed' ? (i.text ?? '') : '';
  let heard: 'typed' | 'transcribed' | 'later' = i.mode !== 'voice' ? 'typed' : 'later';
  if (i.mode === 'voice' && i.audio && r.answer_id) {
    const t0 = Date.now();
    const t = await (await transcriber()).transcribe({ audio: i.audio, type: i.type ?? '', seconds: i.seconds ?? 30, model: r.transcribe_model });
    // a quota refusal made no call: it waits for the interviews job (nothing counted)
    await rpc('server_ai_interview_transcript', { p: { answer_id: r.answer_id, ok: t.ok, text: t.ok ? t.text : null, model: t.model ?? null, neurons: t.neurons ?? 0,
      duration_ms: Date.now() - t0, error: t.ok ? null : t.message, reason: t.ok ? null : t.reason, called: t.ok || t.reason !== 'quota' } as unknown as Json }, SR).catch(() => undefined);
    if (t.ok) { said = t.text; heard = 'transcribed'; }
  }
  // a follow-up where a question's answer is vague (never after a follow-up; at most the setting's number)
  if (r.kind === 'question' && i.mode !== 'none' && (r.followups_left ?? 0) > 0 && heard !== 'later') {
    let model: { vague?: unknown; followup?: unknown } | null = null;
    let call: Record<string, unknown> = { called: false };
    if (words(said) < DETAILED_WORDS) {
      const t0 = Date.now();
      const g = await (await textGenerator(undefined, 20_000)).generate<{ vague: boolean; followup: string }>({ task: 'interview_followup', system: FOLLOWUP_SYSTEM,
        prompt: followupPrompt(r.question ?? '', said), schema: FOLLOWUP_SCHEMA, maxOutputTokens: 80, temperature: 0.2 });
      if (g.ok) model = g.data;
      call = { called: g.ok || g.reason !== 'quota', ok: g.ok, model: g.ok ? g.model : null, neurons: g.usage?.neurons ?? 0, duration_ms: Date.now() - t0, error: g.ok ? null : g.message };
    }
    const text = pickFollowup(said, model);
    if (text || call.called) {
      const v = (await rpc('server_ai_interview_followup', { p_token: token, p: { answer_id: r.answer_id, text, ...call } as unknown as Json }, SR).catch(() => null)) as unknown as InterviewView | Fail | null;
      if (v && v.ok) return { ok: true, view: v, heard };
    }
  }
  return { ok: true, view: r, heard };
}

// ---------------------------------------------------------------- the interviews job (the Worker's tick, when due)
interface Due {
  model: string;
  transcribe: Array<{ answer_id: string; audio_key: string; audio_type: string | null; audio_seconds: number | null }>;
  score: Array<ScoreInput & { interview_id: string; role_slug: string }>;
  topics: Topic[];
  purge: Array<{ answer_id: string; audio_key: string }>;
  videos?: Array<{ answer_id: string; video_key: string }>;
}
export async function runInterviewJob(): Promise<Record<string, unknown>> {
  const due = (await rpc('server_ai_interviews_due', { p_limit: 5 }, SR)) as unknown as Due;
  const { storage } = await import('@/integrations/storage');
  const s = await storage();
  // the audio of applications whose personal data was removed (12 months after the decision)
  const gone: string[] = [];
  for (const p of due.purge) { try { await s.remove('documents', p.audio_key); gone.push(p.answer_id); } catch { /* next run */ } }
  if (gone.length) await rpc('server_ai_audio_purged', { p_ids: gone }, SR);
  // 0585: the videos past Keep interview videos (90 days by default), and those of removed applications
  const vids: string[] = [];
  for (const p of due.videos ?? []) { try { await s.remove('documents', p.video_key); vids.push(p.answer_id); } catch { /* next run */ } }
  if (vids.length) await rpc('server_ai_video_purged', { p_ids: vids }, SR);
  // transcripts left by the answer page (the allowance was used, or the model failed)
  let transcribed = 0;
  const tr = await transcriber();
  for (const a of due.transcribe) {
    const audio = await s.get('documents', a.audio_key);
    const t0 = Date.now();
    const t = audio ? await tr.transcribe({ audio, type: a.audio_type ?? '', seconds: Number(a.audio_seconds ?? 30), model: due.model })
      : { ok: false as const, reason: 'unavailable' as const, message: 'The recording is missing from storage', model: due.model, neurons: 0 };
    await rpc('server_ai_interview_transcript', { p: { answer_id: a.answer_id, ok: t.ok, text: t.ok ? t.text : null, model: t.model ?? null, neurons: t.neurons ?? 0,
      duration_ms: Date.now() - t0, error: t.ok ? null : t.message, reason: t.ok ? null : t.reason, called: t.ok || t.reason !== 'quota' } as unknown as Json }, SR);
    if (t.ok) transcribed++;
    else if (t.reason === 'quota') break;
  }
  // one interview scored a run (background share of the allowance)
  let scored = 0;
  for (const x of due.score) {
    const t0 = Date.now();
    const g = await (await textGenerator(undefined, 60_000)).generate<Record<string, unknown>>({ task: 'interview_score', system: scoreSystem(due.topics, x.va_function === 'sales'),
      prompt: scorePrompt(x), schema: SCORE_SCHEMA, maxOutputTokens: 1200, temperature: 0.2 });
    await rpc('server_ai_interview_scored', { p: { interview_id: x.interview_id, ok: g.ok, result: g.ok ? g.data : null, model: g.ok ? g.model : null,
      neurons: g.usage?.neurons ?? 0, duration_ms: Date.now() - t0, error: g.ok ? null : g.message, reason: g.ok ? null : g.reason,
      called: g.ok || g.reason !== 'quota' } as unknown as Json }, SR);
    if (g.ok) scored++;
  }
  return { ok: true, purged: gone.length, videos_deleted: vids.length, transcribed, scored };
}
