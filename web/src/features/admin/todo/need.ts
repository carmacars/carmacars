import { groupPrompts } from './group.ts';
import type { Todo, TodoItem } from './types.ts';

// What "need you" counts on Admin > To do (migration 0320; docs/changes/2026-11-06-owner-todo-usage-noise.md): one per
// line the page shows, never one per record. Prompts of one kind that repeats are one line (group.ts); a count line is
// one line whatever its count; a team's lines are on its team line and never count. The database says the same
// (app.todo_need, app.todo_team_of): keep the two in step.

/** The count lines whose records already have prompts of their own (not repeated as a count line). */
export const COVERED = new Set(['applications', 'requests', 'changes', 'plates', 'samples', 'first_last_decide', 'signed_copy_failed']);

/** The team of each count line; absent: the Admin's own. */
export const TEAM_OF: Record<string, 'cs' | 'sales' | 'fleet' | 'finance'> = {
  capture_follow_up: 'sales', chauffeur: 'sales',
  maintenance_due: 'fleet', maintenance_unknown: 'fleet', listings: 'fleet', calendar_feeds: 'fleet', turo_emails: 'fleet', insurance: 'fleet',
  maintenance_bill: 'finance', tolls: 'finance', commissions_pay: 'finance', deposits_overdue: 'finance', payments: 'finance'
};

const teamOf = (i: TodoItem) => i.team ?? TEAM_OF[i.key] ?? null;

/** The Admin's own count lines with something waiting, in the database's order. */
export function ownLines(items: TodoItem[]): TodoItem[] {
  return items.filter((i) => i.count > 0 && !teamOf(i) && !COVERED.has(i.key));
}
/** The Admin's own count lines with nothing waiting (the "more with nothing waiting" list). */
export function ownClear(items: TodoItem[]): TodoItem[] {
  return items.filter((i) => i.count === 0 && !teamOf(i) && !COVERED.has(i.key));
}

/** The headline: the database's figure when it gives one, else the same rule here. */
export function needCount(d: Pick<Todo, 'items' | 'prompts' | 'need'>): number {
  if (typeof d.need === 'number') return d.need;
  return groupPrompts((d.prompts ?? []).filter((p) => !(p.kind === 'task' && p.from_queue))).length + ownLines(d.items).length;
}

/** "Customer service has 42 open" (and "3 overdue"); "nothing open" when clear. */
export function teamLine(t: { label: string; open: number; overdue?: number }): string {
  if (!t.open) return `${t.label}: nothing open`;
  return `${t.label} has ${t.open} open${t.overdue ? `, ${t.overdue} overdue` : ''}`;
}

/** The headline sentence. */
export function needSentence(n: number): string {
  return n ? `${n} thing${n > 1 ? 's' : ''} need${n > 1 ? '' : 's'} you, most urgent first.` : 'Nothing needs you right now. New requests and anything that needs you show up here.';
}
