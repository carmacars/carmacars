// r50 hotfix 2 (5150): the weekly Admin call (Abbas and Mahad). The deck is built by the database (app.admin_call_slides);
// this is its shape and the words the page needs. Pure: the page and the unit test share it.
export interface Point { label: string; value: string }
export interface Item { key: string; kind: 'shift' | 'todo' | 'money' | 'deposit' | 'payout'; label: string; detail: string; href: string; approve: string; deny: string;
  decision?: 'approve' | 'deny'; decided_by?: string; decided_at?: string; decision_note?: string | null }
export interface Slide { key: string; title: string; points: Point[]; lines?: string[]; items?: Item[]; note?: string | null }
export interface AdminCall { next_at: string | null; weekday: number; time: string; minutes: number; in_site: boolean; weeks: string[];
  deck: { id: string; week_of: string; call_at: string; built_at: string; slides: Slide[]; decided: number } | null }

export const WEEKDAYS = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'] as const;

/** "Every Sunday at 7:00 pm, 60 minutes" */
export function scheduleWords(v: Pick<AdminCall, 'weekday' | 'time' | 'minutes'>): string {
  const [h, m] = v.time.split(':').map(Number) as [number, number];
  const t = `${((h + 11) % 12) + 1}:${String(m).padStart(2, '0')} ${h < 12 ? 'am' : 'pm'}`;
  return `Every ${WEEKDAYS[v.weekday] ?? 'week'} at ${t} Toronto time, ${v.minutes} minutes`;
}

/** The decisions still open on the deck, and all of them. */
export function openDecisions(slides: Slide[]): { open: number; total: number } {
  const items = slides.flatMap((s) => s.items ?? []);
  return { open: items.filter((i) => !i.decision).length, total: items.length };
}

/** The call's slides for the in-site call (the deck beside the video): points, then lines and the items as lines. */
export function callSlides(slides: Slide[]): Array<{ key: string; title: string; points: Point[]; lines: string[] }> {
  return slides.map((s) => ({ key: s.key, title: s.title, points: s.points ?? [],
    lines: [...(s.lines ?? []), ...(s.items ?? []).map((i) => `${i.label}${i.detail ? `: ${i.detail}` : ''}${i.decision ? ` (${i.decision === 'approve' ? i.approve : i.deny})` : ''}`), ...(s.note ? [s.note] : [])] }));
}
