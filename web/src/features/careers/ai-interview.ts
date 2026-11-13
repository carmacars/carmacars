// The AI interview of the remote assistant roles (migration 0380): what the answer page, the interviews job and the Admin
// page share. Pure: no database, no model. The model only suggests (a follow-up, scores with quotes, a recommendation);
// the database checks what it keeps (app.server_ai_interview_scored) and an Admin decides.

export type InterviewState = 'sent' | 'started' | 'submitted' | 'scored' | 'expired';
export type Recommendation = 'live_call' | 'hire' | 'decline' | 'sales';
export interface NextQuestion { seq: number; kind: 'question' | 'followup'; key: string; text: string }
export interface InterviewView {
  ok: true; id: string; state: InterviewState; first_name: string; role_title: string; expires_at: string; consent_needed: boolean; consent_text: string;
  total: number; answered: number; next: NextQuestion | null;
  /** 0585: the seconds for each answer (Admin > Hiring, Answer time) and the retakes allowed. */
  answer_seconds?: number; retakes?: number;
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

// ---------------------------------------------------------------- the video of an answer (release 30, migration 0585)
/** The answer time when the database gives none (Admin > Hiring, Answer time: 1 to 3 minutes), and the red last seconds. */
export const DEFAULT_ANSWER_SECONDS = 120;
export const LOW_SECONDS = 15;
/** The largest video accepted: 3 minutes at the bitrate asked (about 1 Mbps at 720p) leaves room for a browser that records more. */
export const MAX_VIDEO_BYTES = 60 * 1024 * 1024;
/** What the browser is asked for: about 720p, the sizes it records at, compressed. */
export const VIDEO_CONSTRAINTS = { width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 24, max: 30 }, facingMode: 'user' } as const;
export const VIDEO_BITS = 1_000_000;
export const AUDIO_BITS = 64_000;
/** The video types a browser records (Chrome and Firefox webm, Safari mp4), first supported wins. */
export const VIDEO_TYPES = ['video/mp4;codecs=avc1,mp4a', 'video/webm;codecs=vp9,opus', 'video/webm;codecs=vp8,opus', 'video/webm', 'video/mp4'];
export const AUDIO_TYPES_PREFERRED = ['audio/webm;codecs=opus', 'audio/mp4', 'audio/ogg;codecs=opus', 'audio/webm'];
/** The extension of a video's type, or null for a type we do not keep. */
export function videoExt(type: string): 'webm' | 'mp4' | null {
  const t = (type || '').split(';')[0]!.trim().toLowerCase();
  return t === 'video/webm' ? 'webm' : t === 'video/mp4' || t === 'video/quicktime' ? 'mp4' : null;
}
/** The content type a stored recording is served with: videos end in -v.webm or -v.mp4 (0585), audio by its extension. */
export function recordingMime(key: string): string | null {
  if (/-v\.webm$/.test(key)) return 'video/webm';
  if (/-v\.mp4$/.test(key)) return 'video/mp4';
  return AUDIO_MIME[key.split('.').pop() ?? ''] ?? null;
}
/** The clock of an answer: minutes and seconds, never below 0:00. */
export const clock = (s: number) => { const x = Math.max(0, Math.ceil(s)); return `${Math.floor(x / 60)}:${String(x % 60).padStart(2, '0')}`; };
/** Why the browser cannot record, in plain words (the error of getUserMedia, or none of MediaRecorder). */
export function cannotRecordWhy(err: { name?: string } | null, hasRecorder: boolean): string {
  if (!hasRecorder) return 'This browser cannot record video. Open the same link in Chrome, Safari or Edge, or on another phone or computer.';
  switch (err?.name) {
    case 'NotAllowedError': case 'SecurityError': return 'The camera or microphone is blocked. Allow both for carmacars.ca in your browser (the icon in the address bar), then press Try again.';
    case 'NotFoundError': case 'OverconstrainedError': return 'We could not find a camera and a microphone on this device. The interview is answered on video only: switch to a phone or computer that has both (or another browser) and open the same link again.';
    case 'NotReadableError': case 'AbortError': return 'Another app is using the camera or the microphone. Close it, then press Try again.';
    default: return 'We could not start the camera and the microphone. Press Try again, or switch to another device or browser and open the same link again.';
  }
}

export const words = (s: string | null | undefined) => (s ?? '').trim().split(/\s+/).filter(Boolean).length;
/** Never call the interview a test (the owner's rule: interview, then hire). */
export const TEST_WORDS = /\b(test|tests|tested|exam|exams|quiz|assessment)\b/i;

// ---------------------------------------------------------------- the follow-up after an answer
/** Clear without the model: a long answer is never vague (no call is made). 2590: a probing interview asks the model up to 160 words. */
export const DETAILED_WORDS = 160;
/** Vague without the model: a very short answer gets the plain follow-up when the model cannot be asked. */
export const SHORT_WORDS = 15;
export const PLAIN_FOLLOWUP = 'Could you tell me a bit more, with a real example from your work?';

export const FOLLOWUP_SCHEMA = { type: 'object', properties: { vague: { type: 'boolean' }, followup: { type: 'string' } }, required: ['vague', 'followup'] };
export const FOLLOWUP_SYSTEM = 'You interview applicants for a role at CarmaCars, a car rental company in Toronto. This interview is the pre-screen to our training academy, so the bar is high. You read one answer and decide if it needs a probing follow-up: too short, general, rehearsed, off the question, or missing the specifics asked for (tasks, tools, numbers, a real example, what they said word for word, a clear yes or no). Probe hardest on: how they handle a real situation from the job, how they answer a customer who objects (Sales), their reliability (missed shifts, outages, backup plans), their internet and hours, and whether the pay works. Answer in JSON {"vague": true or false, "followup": "..."}. When vague, followup is ONE short, polite question of at most 25 words that asks for exactly what is missing or tests the claim with a concrete case. When not vague, followup is "". Never call this a test, exam or assessment. Do not judge or praise the answer. Plain words, no long dashes.';
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
    /** 2680: each answer scored out of 10 on its own, with a one-line reason (kept as shown to the Admin under the answer) */
    answers: { type: 'array', items: { type: 'object', properties: { seq: { type: 'integer' }, score: { type: 'integer' }, reason: { type: 'string' } }, required: ['seq', 'score', 'reason'] } },
    english: { type: 'object', properties: { level: { type: 'string', enum: ['fluent', 'good', 'basic'] }, score: { type: 'integer' }, notes: { type: 'string' } }, required: ['level', 'score', 'notes'] },
    red_flags: { type: 'array', items: { type: 'string' } },
    knockouts: { type: 'array', items: { type: 'string' } },
    recommendation: { type: 'string', enum: ['live_call', 'hire', 'decline', 'sales'] },
    reason: { type: 'string' },
    summary: { type: 'string' }
  },
  required: ['topics', 'answers', 'english', 'red_flags', 'knockouts', 'recommendation', 'reason', 'summary']
};

export interface ScoreInput {
  role_title: string; va_function: string | null; hours: string | null; pay_text: string;
  answers: Array<{ seq: number; kind: string; key: string; prompt: string; mode: string; transcript: string }>;
}
/** 1060: an in-person role (field, Sales in person) has no remote setup to score: its "internet" topic is getting around
 *  Toronto for work and the licence. */
export function topicsFor(topics: Topic[], inPerson: boolean): Topic[] {
  if (!inPerson) return topics;
  return topics.map((t) => (t.key === 'internet' ? { ...t, label: 'Getting to work and the licence', good: 'Reliable transport to Toronto locations with a backup plan; a full Ontario G licence with a clean record where the role drives' } : t));
}
export function scoreSystem(topics: Topic[], salesRole: boolean): string {
  return [
    'You help the hiring team of CarmaCars, a car rental company in Toronto, review a recorded interview for a role. The interview is the pre-screen to our training academy: the score decides by itself who is hired into the academy, so be strict and score only what is shown, never what is promised. Every answer was recorded on video, spoken out loud (transcribed by speech-to-text, so small transcription errors are not the candidate\'s).',
    'Score each topic from 1 (poor or not answered) to 5 (excellent) using only what the candidate said. For each topic give as evidence one short quote copied word for word from the answers (empty when nothing was said about it).',
    'Topics (key: label; what good looks like):',
    ...topics.map((t) => `- ${t.key}: ${t.label}; ${t.good}`),
    'Answers: also score every answer on its own from 1 (no answer, off the question or vague) to 10 (specific, honest, convincing, with a real example), by its number (seq, the Q and A number below), with one plain line of reason (200 characters at most). One entry for each answer.',
    'Spoken English: judge clarity, grammar and vocabulary from the wording; level fluent, good or basic, a score 1 to 5, and one sentence of notes.',
    'Red flags: short plain statements of anything that needs checking (refuses the schedule or the pay, works for another car rental business serving Ontario, classes or other jobs during the hours, no backup internet, contradictions, an answer read from somewhere). An empty list when none.',
    'The minimum for every role: at least a year of relevant experience and good spoken English.',
    'Score 5 only for a specific, convincing answer with a real example; 3 for adequate but general; 1 or 2 for vague, rehearsed or missing. The written English topic is judged from the spoken customer message only.',
    'Knock-outs: short plain statements of any answer that rules the candidate out by itself: refuses or cannot work the schedule, refuses the pay, works for another car rental business serving Ontario, classes or another job during the hours, no internet backup for a remote role, no licence where the role drives, an answer clearly read or written by someone else. An empty list when none. Any knock-out fails the interview.',
    `Recommendation, one of: "hire" (clearly strong on every point), "live_call" (promising, with points to check in a short live call), ${salesRole ? '"decline" (the minimum is not met, or a red flag rules them out; never "sales" for this Sales role)' : '"sales" (does not pass for this role but could sell: good English and motivation; this is the usual outcome for a candidate who does not pass), "decline" (only when a red flag rules them out of any role)'}.`,
    'The hiring team decides; you only recommend. Reason: one sentence for the recommendation. Summary: two or three plain sentences about the candidate. Never call the interview a test or an exam. No long dashes.',
    'Answer in JSON with the keys topics, answers, english, red_flags, knockouts, recommendation, reason, summary.'
  ].join('\n');
}
export function scorePrompt(x: ScoreInput): string {
  const qa = x.answers.map((a) => `Q${a.seq}${a.kind === 'followup' ? ' (follow-up)' : ''} [${a.key}]: ${a.prompt}\nA${a.seq} (${a.mode === 'none' ? 'no answer' : 'spoken'}): ${a.transcript.slice(0, 2500)}`).join('\n\n');
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
  const answers = [...prompt.matchAll(/^Q\d+(?: \(follow-up\))? \[([a-z_]+)\]: [^\n]*\nA\d+ \([a-z ]+\): ([^\n]*)$/gm)].map((m) => ({ key: m[1]!, text: m[2]! }));
  const by = (k: string) => answers.filter((a) => a.key === k).map((a) => a.text).join(' ');
  const map: Record<string, string> = { internet: 'internet', english: 'experience', social: 'social', skills: 'skills', experience: 'experience', understanding: 'understanding',
    hours_pay: 'hours_pay', other_jobs: 'other_jobs', education: 'other_jobs', career: 'career', canada: 'career', reliability: 'reliability', written: 'written' };
  const out = topics.map((t) => {
    const text = by(map[t.key] ?? t.key);
    const n = words(text);
    return { key: t.key, score: n === 0 ? 1 : n < 10 ? 2 : n < 25 ? 3 : 4, evidence: text.split(/\s+/).slice(0, 8).join(' ') };
  });
  const avg = out.reduce((s, x) => s + x.score, 0) / Math.max(out.length, 1);
  const per = answers.length ? [...prompt.matchAll(/^Q(\d+)(?: \(follow-up\))? \[[a-z_]+\]: [^\n]*\nA\d+ \([a-z ]+\): ([^\n]*)$/gm)].map((m) => {
    const n = words(m[2]);
    return { seq: Number(m[1]), score: n === 0 ? 1 : n < 10 ? 3 : n < 25 ? 5 : 7, reason: n === 0 ? 'No answer.' : n < 25 ? 'Short and general (fake model).' : 'Detailed enough (fake model).' };
  }) : [];
  return { topics: out, answers: per, english: { level: avg >= 3.5 ? 'good' : 'basic', score: Math.round(avg), notes: 'Read from the transcript (fake model).' },
    red_flags: answers.some((a) => /\bno\b/i.test(a.text) && a.key === 'hours_pay') ? ['Did not agree to the schedule or the pay'] : [],
    knockouts: answers.some((a) => /\bno\b/i.test(a.text) && a.key === 'hours_pay') ? ['Did not agree to the schedule or the pay'] : [],
    recommendation: avg >= 3.5 ? 'live_call' : 'sales', reason: 'Scored by the fake model from the answers.', summary: `Answered ${answers.length} questions.` };
}
