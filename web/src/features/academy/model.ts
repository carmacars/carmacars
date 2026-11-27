// The academy's lessons in the browser (Release 21b, item 9; migration 0207). Pure: the scene types, the voice chosen from the
// browser's list, how long a scene lasts without a voice, and the quiz score. The player (ScenePlayer.tsx) and the pages use it.
import jokes from './jokes.json' with { type: 'json' };
const JOKES: readonly Joke[] = jokes;
export type Visual =
  | { kind: 'title'; heading: string; text?: string }
  | { kind: 'chat'; lines: Array<{ who: string; text: string }> }
  | { kind: 'list' | 'steps'; heading: string; items: string[] }
  | { kind: 'money'; heading: string; rows: Array<[string, string]>; total?: [string, string] }
  | { kind: 'rule'; heading: string; text: string; tone?: 'ok' | 'warn' }
  /** 2990: a guide screenshot (img, a file of docs/guides/content/images.json) and the chapter it is from (portal/slug) */
  | { kind: 'shot'; heading: string; guide: string; img?: string; text?: string }
  /** 4200: a screen or photo (webp in /academy) with numbered pins and a legend; alt is required */
  | { kind: 'pic'; heading: string; src: string; alt: string; w: number; h: number; pins?: Pin[]; text?: string }
  /** 4200: a good and a bad example photo side by side */
  | { kind: 'compare'; heading: string; alt: string; good: ComparePhoto; bad: ComparePhoto }
  /** 4200: an inline SVG diagram of a flow; each step has an icon of the portal icon set */
  | { kind: 'flow'; heading: string; alt: string; steps: Array<{ icon: string; label: string }> }
  /** 4200: Do and Don't pairs */
  | { kind: 'dodont'; heading: string; alt: string; pairs: Array<{ do: string; dont: string }> }
  /** 4200: key steps or facts, each with a small icon */
  | { kind: 'icons'; heading: string; alt: string; items: Array<{ icon: string; text: string }> };
export interface Pin { n: number; x: number; y: number; label: string }
export interface ComparePhoto { src: string; text: string; w: number; h: number }
/** 4200: the scene kinds that are pictures (they carry alt text). */
export const PICTURE_KINDS = ['pic', 'compare', 'flow', 'dodont', 'icons'] as const;
/** 4200: the alt text of a picture scene ('' for a scene that is not one). */
export function visualAlt(v: Visual): string {
  return (PICTURE_KINDS as readonly string[]).includes(v.kind) ? ((v as { alt?: string }).alt ?? '') : '';
}
export interface Scene { caption: string; say?: string; visual: Visual }
export interface Lesson { id: string; title: string; scenes: Scene[]; viewed?: boolean }
export interface SectionView { id: string; slug: string; title: string; blurb: string; path: string; path_title: string; pass_bps: number; passed: boolean; best_bps: number | null; next: string | null;
  lessons: Lesson[]; questions: Array<{ id: string; prompt: string; options: string[] }>;
  /** 1154: the questions come with the started quiz; the reading clock and the waits */ question_count?: number; opened_at?: string | null; quiz?: QuizWait }
/** 1154: may the quiz start now, and if not, why and until when. */
export interface QuizWait { ok: boolean; reason?: 'reading' | 'daily' | 'cooldown'; until?: string; message?: string; read_seconds?: number; tries_left?: number }
/** 1154: a started quiz: questions and options in a random order; keys[i] is the shown option i's index in the question. */
export interface QuizStart { section: string; started_at: string; tries_left?: number; questions: Array<{ id: string; prompt: string; options: string[]; keys: number[]; joke?: number | null }>;
  /** 5070: a first try below the pass mark waiting for its one fix: the wrong questions and the first answers */ fix?: QuizFix }
/** 5070 (fix once): the questions the first check marked wrong (never the right answers) and the answers given then. */
export interface QuizFix { wrong: string[]; given: Record<string, number> }
/** 5070: the first check below the pass mark: no attempt recorded, the wrong questions to fix once. */
export interface QuizFixResult { fix: true; passed: false; wrong: string[]; correct: number; total: number; score_bps: number; pass_bps: number; message: string }
export interface SectionRow { id: string; slug: string; title: string; blurb: string; sort: number; open: boolean; passed: boolean; /** 5170: one of the path's basics */ core?: boolean; unlocked_early: boolean; best_bps: number | null; attempts: number; lessons: number; viewed: number; questions: number; /** 1154 */ flagged?: number; reset_at?: string | null }
export interface PathRow { code: string; title: string; blurb: string; passed: boolean; sections: SectionRow[]; /** 5170 */ core_count?: number; core_passed?: boolean }
/** 5170: the basics (open the portal) and the whole academy (opens the payouts), each section once. */
export interface AcademyCounts { core_passed: number; core_total: number; passed: number; total: number }
/** 5171: a section to pass before continuing an area of the portal (stuck there). */
export interface Required { id: string; area: string; path: string; section: string; title: string; href: string; reason: string; at: string }
export interface QuizResult { correct: number; total: number; score_bps: number; passed: boolean; pass_bps: number; results: Array<{ id: string; given: number | null; answer: number | null; right: boolean; explain: string }>;
  /** 1154 */ quiz?: QuizWait; flagged?: boolean; /** 5070: graded after the one fix */ fixed?: boolean }

/** 4200: the funny wrong answers every question carries (jokes.json): the option text and the playful line for picking it. */
export interface Joke { text: string; quip: string }
/** The joke an option is, if it is one. */
export const jokeOf = (option: string): Joke | undefined => JOKES.find((j) => j.text === option);
/** The playful line for a picked option when it is a joke ('' otherwise). */
export const jokeQuip = (option: string | undefined): string => (option ? jokeOf(option)?.quip ?? '' : '');
/** 4720: the playful line for a question's own joke (questions[].joke of the started quiz), steady for the same joke. */
const OWN_QUIPS = ['Nice try. Funny, but not the answer.', 'Nice try. Good one, wrong one.', 'Nice try. We laughed; the quiz did not.', 'Nice try. Save that one for the townhall.'] as const;
export const ownJokeQuip = (option: string | undefined): string => {
  if (!option) return '';
  let h = 0;
  for (const c of option) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return OWN_QUIPS[h % OWN_QUIPS.length]!;
};

/** The words a scene says: its narration, else its caption. */
export const words = (s: Scene): string => (s.say && s.say.trim()) || s.caption;

/** An English voice: the browser's default English voice first, then en-CA, en-US, en-GB, then any English; null if none. */
export function pickVoice<V extends { lang: string; default?: boolean; localService?: boolean }>(voices: readonly V[]): V | null {
  const en = voices.filter((v) => /^en([-_]|$)/i.test(v.lang));
  if (!en.length) return null;
  const by = (lang: string) => en.find((v) => v.lang.replace('_', '-').toLowerCase() === lang);
  return en.find((v) => v.default) ?? by('en-ca') ?? by('en-us') ?? by('en-gb') ?? en.find((v) => v.localService) ?? en[0]!;
}

/** How long a scene shows when there is no voice (captions only): reading time at about 2.6 words a second, 3 to 20 seconds. */
export function sceneMs(s: Scene, speed = 1): number {
  const n = words(s).split(/\s+/).filter(Boolean).length;
  return Math.round(Math.min(20000, Math.max(3000, (n / 2.6) * 1000 + 1200)) / speed);
}

/** The progress of a lesson, 0 to 1: scenes done and the share of the current one. */
export const progress = (index: number, within: number, count: number): number => (count ? Math.min(1, (index + Math.min(1, Math.max(0, within))) / count) : 0);

/** "80%" from basis points. */
export const pct = (bps: number | null | undefined): string => (bps === null || bps === undefined ? '' : `${Math.floor(bps / 100)}%`);

/** 1154: the minutes and seconds left until a time, "4:05"; "" when it has passed. */
export function waitLeft(untilIso: string | undefined, now: number): string {
  if (!untilIso) return '';
  const ms = Date.parse(untilIso) - now;
  if (!(ms > 0)) return '';
  const t = Math.ceil(ms / 1000);
  const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), sec = t % 60;
  return h ? `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}` : `${m}:${String(sec).padStart(2, '0')}`;
}

/** 2990: where a guide chapter (portal/slug) opens for the person: staff read the renter guide at /staff/guide/renter and
 *  their own guides at /staff/guide and /staff/field/guide; an Admin reads every guide under /admin/guide. */
export function guideHref(ref: string, admin = false): string {
  const [portal = 'va', slug = ''] = ref.split('/');
  const hash = slug ? `#${slug}` : '';
  if (admin) return portal === 'admin' ? `/admin/guide${hash}` : `/admin/guide/${portal}${hash}`;
  if (portal === 'renter') return `/staff/guide/renter${hash}`;
  if (portal === 'field') return `/staff/field/guide${hash}`;
  return `/staff/guide${hash}`;
}
/** 2990: the address of a guide screenshot. */
export const shotSrc = (img: string): string => `/guides/img/${img}`;

/** 2990: the due date of new sections for staff already working (their enrollment's lock_from, still ahead): null when
 *  everything is passed, the date has come, or there is none. */
export function dueWords(lockFrom: string | null | undefined, allPassed: boolean, now = Date.now()): string | null {
  if (allPassed || !lockFrom) return null;
  const t = Date.parse(lockFrom);
  if (!(t > now)) return null;
  const day = new Date(t).toLocaleDateString('en-CA', { timeZone: 'America/Toronto', weekday: 'short', month: 'short', day: 'numeric' });
  return `New sections to pass by ${day}. After that, the rest of your portal waits until they are passed.`;
}

/** Words broken into lines of at most `max` characters. */
export function wrapLabel(text: string, max: number): string[] {
  const out: string[] = [];
  let line = '';
  for (const w of text.split(/\s+/).filter(Boolean)) {
    if (line && (line + ' ' + w).length > max) { out.push(line); line = w; } else line = line ? `${line} ${w}` : w;
  }
  if (line) out.push(line);
  return out;
}

