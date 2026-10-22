import type { Prompt } from './types.ts';

// 0104: work of one kind that repeats (72 cars to photograph, 10 services to record) is one line, "Add real photos
// (72 cars)", whose button opens the list; every title stays short.
const GROUP_TITLE: Partial<Record<string, string>> = {
  photos: 'Add real photos', plates: 'Check the plates', trim: 'Pick the trim', specs: 'Confirm gearbox and seats', insurer: 'Confirm with the insurer',
  publish: 'Set rates and publish', documents: 'Check renters\' documents', chat: 'Visitors waiting in live chat', requests: 'Answer booking requests',
  changes: 'Changes renters asked for', applications: 'Decide owner applications', invoice_payment: 'Owner invoices waiting for payment',
  invoice_draft: 'Draft invoices to send or void', paper: 'Record paper signatures', forms: 'Check the official forms', terms: 'Enter agreed owner terms',
  first_last_paid: 'Record the first and last month paid'
};
const groupKey = (p: Prompt) => (p.kind === 'task' ? `task:${p.task_type ?? ''}` : p.kind);
// each of these is a decision about one person, booking or owner, and stays a line of its own; the insurer has its own
// "several at once" line (insurer_bulk)
const ALONE = new Set<string>(['chat', 'requests', 'changes', 'documents', 'applications', 'insurer', 'insurer_bulk', 'publish', 'invoice_payment', 'paper', 'first_last_paid', 'terms']);
/** From this many lines of one kind of work, they are one line. */
export const GROUP_MIN = 3;
/** The short title of a group of tasks: the words their titles share before the colon ("Record the last service"). */
function taskGroupTitle(items: Prompt[]): string {
  const heads = items.map((p) => p.title.split(':')[0]!.trim());
  const same = heads.every((h) => h === heads[0]) ? heads[0]! : '';
  return short(same || items[0]!.title, 48);
}
export const short = (t: string, max = 72) => (t.length > max ? `${t.slice(0, max - 1).replace(/[\s,;:]+\S*$/, '')}...` : t);
const unit = (items: Prompt[]) => (items.every((p) => p.vehicle_id) ? (items.length === 1 ? 'car' : 'cars') : items.length === 1 ? 'item' : 'items');

export type PromptLine = { key: string; one: Prompt } | { key: string; title: string; priority: 1 | 2 | 3; items: Prompt[] };
/** One line per prompt, or one per kind of work that repeats, in the order of its most urgent prompt. Pure. */
export function groupPrompts(prompts: Prompt[]): PromptLine[] {
  const by = new Map<string, Prompt[]>();
  for (const p of prompts) { const k = groupKey(p); by.set(k, [...(by.get(k) ?? []), p]); }
  const grouped = (k: string, p: Prompt) => (by.get(k)!.length >= GROUP_MIN && !ALONE.has(p.kind));
  const out: PromptLine[] = [];
  const seen = new Set<string>();
  for (const p of prompts) {
    const k = groupKey(p);
    if (!grouped(k, p)) { out.push({ key: p.key, one: p }); continue; }
    if (seen.has(k)) continue;
    seen.add(k);
    const items = by.get(k)!;
    const base = p.kind === 'task' ? taskGroupTitle(items) : GROUP_TITLE[p.kind] ?? short(p.title, 48);
    out.push({ key: `group:${k}`, title: `${base} (${items.length} ${unit(items)})`, priority: Math.min(...items.map((x) => x.priority)) as 1 | 2 | 3, items });
  }
  return out;
}

