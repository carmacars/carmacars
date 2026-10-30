// The academy's lessons in the browser (Release 21b, item 9; migration 0207). Pure: the scene types, the voice chosen from the
// browser's list, how long a scene lasts without a voice, and the quiz score. The player (ScenePlayer.tsx) and the pages use it.
export type Visual =
  | { kind: 'title'; heading: string; text?: string }
  | { kind: 'chat'; lines: Array<{ who: string; text: string }> }
  | { kind: 'list' | 'steps'; heading: string; items: string[] }
  | { kind: 'money'; heading: string; rows: Array<[string, string]>; total?: [string, string] }
  | { kind: 'rule'; heading: string; text: string; tone?: 'ok' | 'warn' };
export interface Scene { caption: string; say?: string; visual: Visual }
export interface Lesson { id: string; title: string; scenes: Scene[]; viewed?: boolean }
export interface SectionView { id: string; slug: string; title: string; blurb: string; path: string; path_title: string; pass_bps: number; passed: boolean; best_bps: number | null; next: string | null;
  lessons: Lesson[]; questions: Array<{ id: string; prompt: string; options: string[] }> }
export interface SectionRow { id: string; slug: string; title: string; blurb: string; sort: number; open: boolean; passed: boolean; unlocked_early: boolean; best_bps: number | null; attempts: number; lessons: number; viewed: number; questions: number }
export interface PathRow { code: string; title: string; blurb: string; passed: boolean; sections: SectionRow[] }
export interface QuizResult { correct: number; total: number; score_bps: number; passed: boolean; pass_bps: number; results: Array<{ id: string; given: number | null; answer: number; right: boolean; explain: string }> }

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
