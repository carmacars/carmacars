// Self-heal that learns (release 28, B6; .github/workflows/self-heal.yml and .github/self-heal/heal.mjs). Pure: what was
// seen (the probes), the runbook (.github/self-heal/runbook.json: known failure signatures and their known safe action)
// and the ledger (every earlier incident: signature, action, outcome) decide what this run does. The workflow does the
// I/O; the unit tests (decide.test.ts) prove the rules. Runs without Claude.
//
// The rules:
//  - a signature in the runbook is handled by its action, never more often than its cooldown; reboot and every
//    vps-ops action at most once in 6 hours (the guard the workflow had), and nothing ever runs SQL
//  - a signature not in the runbook is learned from the ledger: when people closed an earlier incident of the same
//    signature with a fix line ("self-heal: <signature> => <action>") naming a safe action, that action is used from
//    then on; otherwise an issue is opened (one per signature, updated while it lasts)
//  - an action taken twice in one incident that did not end it is not taken again: an issue is opened
//  - each incident is recorded once when it starts (signature, action) and once when it ends (outcome)

export type Action = 'wait' | 'reboot' | 'apply_retention' | 'rerun_failed' | 'dispatch_backup' | 'notify';
/** The actions self-heal may ever take: none runs SQL; reboot and apply_retention are vps-ops actions. */
export const SAFE_ACTIONS: readonly Action[] = ['wait', 'reboot', 'apply_retention', 'rerun_failed', 'dispatch_backup', 'notify'];
/** The vps-ops actions, never more than one in 6 hours together. */
export const VPS_ACTIONS: readonly Action[] = ['reboot', 'apply_retention'];
export const VPS_COOLDOWN_H = 6;

export interface RunbookEntry {
  /** what it means, for the issue and the ledger */ about: string;
  action: Action;
  /** hours before the same action is taken again for this signature */ cooldown_h: number;
  /** runs in a row the signature must be seen before acting (an outage must last; a blip must not reboot) */ after_runs?: number;
  /** a "wait" signature still opens an issue once it lasts this many hours */ escalate_after_h?: number;
}
export type Runbook = Record<string, RunbookEntry>;

export interface LedgerEntry {
  at: string;              // ISO time
  signature: string;
  event: 'start' | 'action' | 'end' | 'learned';
  action?: Action;
  outcome?: 'recovered';
  detail?: string;
}

export interface Probe {
  /** the signatures seen now, each with a short detail */ seen: Record<string, string>;
  /** how many runs in a row each signature has been seen (this run included) */ streak: Record<string, number>;
  /** when the last vps-ops run started (any action), ISO, or null */ lastVpsOps: string | null;
  /** fix lines found on closed self-heal issues: "self-heal: <signature> => <action>" */ fixes: Array<{ signature: string; action: string }>;
  /** the live backend is the company's server (vps): the vps-ops actions apply */ vps: boolean;
}

export interface Plan {
  actions: Array<{ signature: string; action: Action; why: string }>;
  issues: Array<{ signature: string; title: string; body: string }>;
  ledger: LedgerEntry[];
  /** signatures that ended this run */ ended: string[];
  /** the runbook with what was learned this run (to write back to the ledger, not to the repository) */ learned: Record<string, Action>;
}

const hoursSince = (iso: string | null | undefined, now: Date) => (iso ? (now.getTime() - new Date(iso).getTime()) / 3_600_000 : Infinity);

/** Signatures open (started and not ended) in the ledger, with their start time. */
export function openIncidents(ledger: LedgerEntry[]): Map<string, string> {
  const open = new Map<string, string>();
  for (const e of [...ledger].sort((a, b) => a.at.localeCompare(b.at))) {
    if (e.event === 'start') open.set(e.signature, e.at);
    else if (e.event === 'end') open.delete(e.signature);
  }
  return open;
}

/** What the ledger and the fix lines teach: signature => action (safe actions only; the latest wins). */
export function learnedActions(ledger: LedgerEntry[], fixes: Probe['fixes']): Record<string, Action> {
  const out: Record<string, Action> = {};
  for (const e of [...ledger].sort((a, b) => a.at.localeCompare(b.at))) if (e.event === 'learned' && e.action && SAFE_ACTIONS.includes(e.action)) out[e.signature] = e.action;
  for (const f of fixes) if ((SAFE_ACTIONS as readonly string[]).includes(f.action)) out[f.signature] = f.action as Action;
  return out;
}

/** The action was already taken twice in this incident (since it started) and the signature is still seen: it did not help. */
export function failedTwice(ledger: LedgerEntry[], signature: string, action: Action, since: string | undefined): boolean {
  if (!since) return false;
  return ledger.filter((e) => e.signature === signature && e.event === 'action' && e.action === action && e.at >= since).length >= 2;
}

export function decide(p: Probe, runbook: Runbook, ledger: LedgerEntry[], now: Date = new Date()): Plan {
  const at = now.toISOString();
  const plan: Plan = { actions: [], issues: [], ledger: [], ended: [], learned: {} };
  const open = openIncidents(ledger);
  const learned = learnedActions(ledger, p.fixes);
  for (const f of p.fixes) if ((SAFE_ACTIONS as readonly string[]).includes(f.action) && !ledger.some((e) => e.event === 'learned' && e.signature === f.signature && e.action === f.action)) {
    plan.ledger.push({ at, signature: f.signature, event: 'learned', action: f.action as Action, detail: 'from a fix line on a closed issue' });
    plan.learned[f.signature] = f.action as Action;
  }
  let vpsUsed = hoursSince(p.lastVpsOps, now) < VPS_COOLDOWN_H;

  // what ended: open incidents no longer seen
  for (const [sig] of open) {
    if (p.seen[sig] === undefined) {
      plan.ended.push(sig);
      plan.ledger.push({ at, signature: sig, event: 'end', outcome: 'recovered' });
    }
  }

  for (const [sig, detail] of Object.entries(p.seen)) {
    const started = open.get(sig);
    if (!started) plan.ledger.push({ at, signature: sig, event: 'start', detail });
    // a signature may carry what it is about after a colon (cron_failed:gsc): the runbook knows the kind
    const known = runbook[sig] ?? runbook[sig.split(':')[0]!];
    const action: Action | undefined = known?.action ?? learned[sig];
    const lastAction = [...ledger].reverse().find((e) => e.signature === sig && e.event === 'action');
    if (!action) {
      plan.issues.push({ signature: sig, title: `Self-heal: unknown failure "${sig}"`, body: `Seen: ${detail}. Not in the runbook (.github/self-heal/runbook.json) and nothing learned for it yet. When it is fixed, close this issue with a line "self-heal: ${sig} => <action>" (one of ${SAFE_ACTIONS.join(', ')}) and self-heal applies that action the next time.` });
      continue;
    }
    if (action !== 'wait' && action !== 'notify' && failedTwice(ledger, sig, action, started)) {
      plan.issues.push({ signature: sig, title: `Self-heal: "${sig}" did not heal`, body: `Seen: ${detail}. The known action (${action}) did not help twice in a row, so it is not taken again until a person looks. docs/runbook-outage.md.` });
      continue;
    }
    if ((known?.after_runs ?? 1) > (p.streak[sig] ?? 1)) continue;   // not long enough yet
    if (action === 'notify') {
      plan.issues.push({ signature: sig, title: `Self-heal: ${known?.about ?? sig}`, body: `Seen: ${detail}. This needs a person (the runbook's action is notify). docs/runbook-outage.md.` });
      continue;
    }
    if (action === 'wait') {
      const since = hoursSince(started ?? at, now);
      if (known?.escalate_after_h !== undefined && since >= known.escalate_after_h) {
        plan.issues.push({ signature: sig, title: `Self-heal: ${known.about} for over ${known.escalate_after_h} hours`, body: `Seen: ${detail}, since ${started ?? at}. Expected to clear by itself; it has not. docs/runbook-outage.md.` });
      }
      continue;
    }
    if (VPS_ACTIONS.includes(action)) {
      if (!p.vps) continue;
      if (vpsUsed) continue;
    }
    if (lastAction && hoursSince(lastAction.at, now) < (known?.cooldown_h ?? 6)) continue;
    plan.actions.push({ signature: sig, action, why: known ? `runbook: ${known.about}` : 'learned from an earlier fix' });
    plan.ledger.push({ at, signature: sig, event: 'action', action, detail });
    if (VPS_ACTIONS.includes(action)) vpsUsed = true;
  }
  return plan;
}
