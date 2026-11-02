// The AI interview of the remote assistant roles (migration 0380): what the answer page, the interviews job and the Admin
// page share. Pure: no database, no model. The model only suggests (a follow-up, scores with quotes, a recommendation);
// the database checks what it keeps (app.server_ai_interview_scored) and an Admin decides.

export type InterviewState = 'sent' | 'started' | 'submitted' | 'scored' | 'expired';
export type Recommendation = 'live_call' | 'hire' | 'decline' | 'sales';
export interface NextQuestion { seq: number; kind: 'question' | 'followup'; key: string; text: string }
export interface InterviewView {
  ok: true; id: string; state: InterviewState; first_name: string; role_title: string; expires_at: string; consent_needed: boolean; consent_text: string;
  total: number; answered: number; next: NextQuestion | null;
}
export interface Topic { key: string; label: string; weight: number; good: string }

export const RECOMMENDATION_WORDS: Record<Recommendation, string> = {
  live_call: 'Invite to a live call', hire: 'Hire', decline: 'Decline', sales: 'Good fit for Sales instead'
};
export const AI_STATE_WORDS: Record<InterviewState, string> = {
  sent: 'AI interview sent', started: 'AI interview started', submitted: 'AI interview done: scoring', scored: 'AI interview done', expired: 'AI interview link expired'
};

/** The longest answer recorded (the recorder stops itself), and the largest file accepted. */
export const MAX_ANSWER_SECONDS = 150;
export const MAX_AUDIO_BYTES = 8 * 1024 * 1024;
/** The audio types a browser records (MediaRecorder: Chrome and Firefox webm or ogg, Safari mp4), with the file extension. */
const AUDIO_TYPES: Record<string, string> = { 'audio/webm': 'webm', 'video/webm': 'webm', 'audio/ogg': 'ogg', 'audio/mp4': 'm4a', 'video/mp4': 'm4a', 'audio/x-m4a': 'm4a',
  'audio/aac': 'm4a', 'audio/mpeg': 'mp3', 'audio/wav': 'wav', 'audio/x-wav': 'wav' };
/** The extension of a recording's type (codecs ignored), or null for a type we do not keep. */
export function audioExt(type: string): string | null {
  return AUDIO_TYPES[(type || '').split(';')[0]!.trim().toLowerCase()] ?? null;
}
export const AUDIO_MIME: Record<string, string> = { webm: 'audio/webm', ogg: 'audio/ogg', m4a: 'audio/mp4', mp3: 'audio/mpeg', wav: 'audio/wav' };

export const words = (s: string | null | undefined) => (s ?? '').trim().split(/\s+/).filter(Boolean).length;
/** Never call the interview a test (the owner's rule: interview, then hire). */
export const TEST_WORDS = /\b(test|tests|tested|exam|exams|quiz|assessment)\b/i;

// ---------------------------------------------------------------- the follow-up after an answer
/** Clear without the model: a long answer is never vague (no call is made). */
export const DETAILED_WORDS = 70;
/** Vague without the model: a very short answer gets the plain follow-up when the model cannot be asked. */
export const SHORT_WORDS = 15;
export const PLAIN_FOLLOWUP = 'Could you tell me a bit more, with a real example from your work?';

export const FOLLOWUP_SCHEMA = { type: 'object', properties: { vague: { type: 'boolean' }, followup: { type: 'string' } }, required: ['vague', 'followup'] };
export const FOLLOWUP_SYSTEM = 'You interview applicants for a remote assistant role at CarmaCars, a car rental company in Toronto. You read one answer and decide if it is vague: too short, general, off the question, or missing the specifics asked for (tasks, tools, numbers, examples, a clear yes or no). Answer in JSON {"vague": true or false, "followup": "..."}. When vague, followup is ONE short, friendly question of at most 25 words that asks for exactly what is missing. When not vague, followup is "". Never call this a test, exam or assessment. Do not judge or praise the answer. Plain words, no long dashes.';
export function followupPrompt(question: string, answer: string): string {
  return `<question>\n${question}\n</question>\n<answer>\n${answer.slice(0, 3000)}\n</answer>`;
}
/** The follow-up to ask (empty: none), from the model's answer or, without one, from the answer's length. */
export function pickFollowup(answer: string, model: { vague?: unknown; followup?: unknown } | null): string {
  const n = words(answer);
  if (n >= DETAILED_WORDS) return '';
  if (model) {
    if (model.vague !== true) return '';
    const f = cleanLine(String(model.followup ?? ''), 200);
    if (f && !TEST_WORDS.test(f) && words(f) <= 30 && f.endsWith('?')) return f;
    return n < SHORT_WORDS ? PLAIN_FOLLOWUP : '';
  }
  return n < SHORT_WORDS ? PLAIN_FOLLOWUP : '';
}
export const cleanLine = (s: string, max: number) => s.replace(/\s+/g, ' ').replace(/—/g, ',').replace(/–/g, '-').trim().slice(0, max);

// ---------------------------------------------------------------- the scores and the recommendation
export const SCORE_SCHEMA = {
  type: 'object',
  properties: {
    topics: { type: 'array', items: { type: 'object', properties: { key: { type: 'string' }, score: { type: 'integer' }, evidence: { type: 'string' } }, required: ['key', 'score', 'evidence'] } },
    english: { type: 'object', properties: { level: { type: 'string', enum: ['fluent', 'good', 'basic'] }, score: { type: 'integer' }, notes: { type: 'string' } }, required: ['level', 'score', 'notes'] },
    red_flags: { type: 'array', items: { type: 'string' } },
    recommendation: { type: 'string', enum: ['live_call', 'hire', 'decline', 'sales'] },
    reason: { type: 'string' },
    summary: { type: 'string' }
  },
  required: ['topics', 'english', 'red_flags', 'recommendation', 'reason', 'summary']
};

export interface ScoreInput {
  role_title: string; va_function: string | null; hours: string | null; pay_text: string;
  answers: Array<{ seq: number; kind: string; key: string; prompt: string; mode: string; transcript: string }>;
}
export function scoreSystem(topics: Topic[], salesRole: boolean): string {
  return [
    'You help the hiring team of CarmaCars, a car rental company in Toronto, review a recorded interview for a remote assistant role. The candidate answered each question out loud (transcribed by speech-to-text, so small transcription errors are not the candidate\'s) or in writing.',
    'Score each topic from 1 (poor or not answered) to 5 (excellent) using only what the candidate said. For each topic give as evidence one short quote copied word for word from the answers (empty when nothing was said about it).',
    'Topics (key: label; what good looks like):',
    ...topics.map((t) => `- ${t.key}: ${t.label}; ${t.good}`),
    'Spoken English: judge clarity, grammar and vocabulary from the wording; level fluent, good or basic, a score 1 to 5, and one sentence of notes.',
    'Red flags: short plain statements of anything that needs checking (refuses the schedule or the pay, works for another car rental business serving Ontario, classes or other jobs during the hours, no backup internet, contradictions, an answer read from somewhere). An empty list when none.',
    'The minimum for every role: at least a year of relevant experience and good spoken English.',
    `Recommendation, one of: "hire" (clearly strong on every point), "live_call" (promising, with points to check in a short live call), ${salesRole ? '"decline" (the minimum is not met, or a red flag rules them out; never "sales" for this Sales role)' : '"sales" (does not pass for this role but could sell: good English and motivation; this is the usual outcome for a candidate who does not pass), "decline" (only when a red flag rules them out of any role)'}.`,
    'The hiring team decides; you only recommend. Reason: one sentence for the recommendation. Summary: two or three plain sentences about the candidate. Never call the interview a test or an exam. No long dashes.',
    'Answer in JSON with the keys topics, english, red_flags, recommendation, reason, summary.'
  ].join('\n');
}
export function scorePrompt(x: ScoreInput): string {
  const qa = x.answers.map((a) => `Q${a.seq}${a.kind === 'followup' ? ' (follow-up)' : ''} [${a.key}]: ${a.prompt}\nA${a.seq} (${a.mode === 'voice' ? 'spoken' : 'typed'}): ${a.transcript.slice(0, 2500)}`).join('\n\n');
  return `<role>${x.role_title}. Hours: ${x.hours ?? 'see the job page'} Pay: ${x.pay_text}</role>\n<interview>\n${qa}\n</interview>`;
}

/** About what a transcription costs: Whisper large v3 turbo is 46.63 neurons a minute of audio (Workers AI pricing). */
export function transcribeNeurons(seconds: number, perMinute = 46.63): number {
  return Math.max(1, Math.ceil((Math.max(seconds, 1) / 60) * perMinute));
}

// ---------------------------------------------------------------- the fake model (tests and local work)
/** A deterministic follow-up: vague below 25 words. */
export function fakeFollowup(prompt: string): { vague: boolean; followup: string } {
  const answer = /<answer>\n([\s\S]*?)\n<\/answer>/.exec(prompt)?.[1] ?? '';
  return words(answer) < 25 ? { vague: true, followup: 'Could you give one specific example, with the tools you used and how often?' } : { vague: false, followup: '' };
}
/** Deterministic scores from the answers' lengths, each with a real quote: the first words of the answer to its question. */
export function fakeScores(prompt: string, topics: Array<Pick<Topic, 'key'>>): Record<string, unknown> {
  const answers = [...prompt.matchAll(/^Q\d+(?: \(follow-up\))? \[([a-z_]+)\]: [^\n]*\nA\d+ \([a-z]+\): ([^\n]*)$/gm)].map((m) => ({ key: m[1]!, text: m[2]! }));
  const by = (k: string) => answers.filter((a) => a.key === k).map((a) => a.text).join(' ');
  const map: Record<string, string> = { internet: 'internet', english: 'experience', social: 'social', skills: 'skills', experience: 'experience', understanding: 'understanding',
    hours_pay: 'hours_pay', other_jobs: 'other_jobs', education: 'other_jobs', career: 'career', canada: 'career' };
  const out = topics.map((t) => {
    const text = by(map[t.key] ?? t.key);
    const n = words(text);
    return { key: t.key, score: n === 0 ? 1 : n < 10 ? 2 : n < 25 ? 3 : 4, evidence: text.split(/\s+/).slice(0, 8).join(' ') };
  });
  const avg = out.reduce((s, x) => s + x.score, 0) / Math.max(out.length, 1);
  return { topics: out, english: { level: avg >= 3.5 ? 'good' : 'basic', score: Math.round(avg), notes: 'Read from the transcript (fake model).' },
    red_flags: answers.some((a) => /\bno\b/i.test(a.text) && a.key === 'hours_pay') ? ['Did not agree to the schedule or the pay'] : [],
    recommendation: avg >= 3.5 ? 'live_call' : 'sales', reason: 'Scored by the fake model from the answers.', summary: `Answered ${answers.length} questions.` };
}
