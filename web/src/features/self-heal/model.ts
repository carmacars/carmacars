// Self-healing (release 50, migration 4800): what app.heal_status returns, and the words the page shows. Pure, so the page and
// the unit tests share it (model.test.ts).

export type HealSource = 'uptime' | 'data_health' | 'site_error' | 'gsc' | 'cron' | 'queue' | 'server';
export type IncidentStatus = 'open' | 'healing' | 'healed' | 'escalated';

export interface HealAttempt { at: string; action: string; playbook: string | null; result: 'ok' | 'error' | 'queued' | 'refused'; verified: boolean | null; details: Record<string, unknown> }
export interface HealIncident {
  id: string; number: number; source: HealSource; key: string; title: string; detail: string | null; state: string | null; path: string | null;
  status: IncidentStatus; money: boolean; first_seen: string; last_seen: string; seen_count: number; attempts: number;
  healed_at: string | null; healed_by: 'playbook' | 'itself' | 'staff' | null; escalated_at: string | null; escalation_reason: string | null; saved_playbook_id: string | null;
  todo_id: string | null; bug_report_id: string | null; resolution_note: string | null; evidence: Record<string, unknown>; tried: HealAttempt[];
}
export interface HealPlaybook {
  id: string; key: string; title: string; source: HealSource; match_key: string | null; match_pattern: string | null; match_state: string | null;
  action: string; action_label: string; action_kind: 'db' | 'server'; params: Record<string, unknown>; max_attempts: number; cooldown_minutes: number;
  verify_minutes: number; enabled: boolean; successes: number; failures: number; consecutive_failures: number; last_run_at: string | null;
  disabled_reason: string | null; builtin: boolean; learned_from: string | null;
}
export interface HealAction { key: string; label: string; kind: 'db' | 'server'; description: string }
export interface HealStatus {
  enabled: boolean;
  counts: { open: number; escalated: number; healed_7d: number; healed_by_playbook_7d: number; attempts_7d: number };
  incidents: HealIncident[]; playbooks: HealPlaybook[]; actions: HealAction[];
  server: { reported_at: string | null; web_tag: string | null; previous_tag: string | null; deployed_at: string | null; web_health: string | null;
    disk_pct: number | null; cert_days: number | null; problems: unknown[]; local_actions: Array<{ at?: string; action?: string; ok?: boolean; result?: string }> } | null;
  requests: Array<{ id: number; action: string; status: string; created_at: string; finished_at: string | null; ok: boolean | null; result: string | null }>;
  note: string;
}

export const SOURCE_WORDS: Record<HealSource, string> = {
  uptime: 'Site check', data_health: 'Data health', site_error: 'Site errors', gsc: 'Search Console', cron: 'Scheduled job', queue: 'Queue', server: 'Server'
};

export const STATUS_WORDS: Record<IncidentStatus, string> = { open: 'Open', healing: 'Fixing', healed: 'Fixed', escalated: 'Needs you' };

/** One line for an attempt: what ran and what the check after it found. */
export function attemptWords(a: HealAttempt): string {
  const what = a.playbook ?? a.action;
  if (a.result === 'error') return `${what}: could not run${typeof a.details?.error === 'string' ? ` (${a.details.error})` : ''}`;
  if (a.result === 'refused') return `${what}: refused`;
  if (a.verified === true) return `${what}: the problem was gone after it`;
  if (a.verified === false) return `${what}: the problem was still there${typeof a.details?.check === 'string' && a.details.check !== 'Still there after the fix' ? ` (${a.details.check})` : ''}`;
  if (a.result === 'queued') return `${what}: waiting for the server`;
  return `${what}: done, checking`;
}

/** How a healed incident was healed, in a few words. */
export function healedWords(i: Pick<HealIncident, 'status' | 'healed_by'>): string {
  if (i.status !== 'healed') return STATUS_WORDS[i.status];
  return i.healed_by === 'playbook' ? 'Fixed by itself' : i.healed_by === 'staff' ? 'Resolved by an Admin' : 'Cleared on its own';
}

/** A playbook's success rate as a whole percent, or null before it has run. */
export function successRate(p: Pick<HealPlaybook, 'successes' | 'failures'>): number | null {
  const n = p.successes + p.failures;
  return n ? Math.round((p.successes / n) * 100) : null;
}

/** The actions a staff member may save as a fix for an incident: any whitelisted action, the ones of its source first. */
export function saveOptions(actions: HealAction[], playbooks: HealPlaybook[], source: HealSource): Array<[string, string]> {
  const used = new Set(playbooks.filter((p) => p.source === source).map((p) => p.action));
  return [...actions].sort((a, b) => Number(used.has(b.key)) - Number(used.has(a.key)))
    .map((a) => [a.key, `${a.label}${a.kind === 'server' ? ' (server)' : ''}`]);
}

/** Incidents split for the page: what needs a person, what the site is working on, and the quiet log of what healed. */
export function splitIncidents(list: HealIncident[]) {
  return {
    escalated: list.filter((i) => i.status === 'escalated'),
    working: list.filter((i) => i.status === 'open' || i.status === 'healing'),
    healed: list.filter((i) => i.status === 'healed')
  };
}
