// The usage guard (migration 0080): the words each paused feature shows, and what continuing costs. Pure, so the unit
// tests read the same sentences the screens show. The numbers come from the database (app.usage_state).

export type UsageState = 'ok' | 'warn' | 'used_up' | 'paused' | 'paid' | 'held' | 'over' | 'free';
export interface ServiceState {
  service: string; label: string; provider: string; unit: string; period: 'day' | 'month' | 'size';
  used: number; included: number; unlimited: boolean; share_bps: number; warn_bps: number; used_text: string; included_text: string;
  period_start: string; resets_at: string | null; state: UsageState; paused: boolean; pause_mode: 'pause' | 'hold' | 'alert'; enabled: boolean;
  decision: { id: string; decision: 'allow' | 'keep_paused'; until: 'day' | 'month'; ends_on: string; cap_usd: number | null; spent_usd: number; decided_at: string; by: string | null } | null;
  overage_usd: number; usd_per_unit: number | null; price_text: string; upgrade_text: string | null; measured_by: string; when_used_up: string;
  measured_at: string | null; sources: string[];
}

/** What a visitor or a staff member reads while a feature waits for its allowance. One sentence each, no error words. */
export const PAUSE = {
  chat: 'Our assistant is resting until tomorrow. A person will answer you here.',
  assistant: 'The assistant is unavailable until tomorrow (daily included usage reached). Everything still works from the screens and pop-ups.',
  assistantClaude: 'The assistant is paused: its Claude budget for today is used (or not allowed yet). An Admin can allow it in Settings > Usage. Everything still works from the screens and pop-ups.',
  copy: 'AI copy waits for tomorrow (daily included usage reached). The template text stays on the page until then.',
  turoEmail: 'Turo emails are read by the rules only until tomorrow (daily included AI usage reached). Emails the rules cannot read wait in the review list.',
  photos: 'Included image transformations are used up for this month: the original photo is used, and the studio background is tried again when the allowance allows.',
  emailsHeld: 'Some emails are waiting: the email plan\'s included emails are used for now. Booking, payment and sign-in emails still go first; the others are sent when the count resets.'
} as const;

/** The pause message of a feature for a gate's state, or null when it may run. */
export function pauseMessage(feature: keyof typeof PAUSE, gate: { ok?: boolean; paused?: boolean; service?: string } | null | undefined): string | null {
  if (!gate || gate.ok !== false) return null;
  if (feature === 'assistant' && gate.service === 'claude') return PAUSE.assistantClaude;
  return PAUSE[feature];
}

export const usd = (n: number | null | undefined) => `US$${(Math.round((n ?? 0) * 100) / 100).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

/** What allowing paid usage would cost at the current rates: per unit, a typical day above the allowance, and the cap. */
export function paidCost(s: Pick<ServiceState, 'service' | 'unit' | 'usd_per_unit' | 'included' | 'period' | 'pause_mode' | 'upgrade_text' | 'overage_usd'>): { rate: string; example: string; canPay: boolean } {
  if (s.pause_mode === 'hold') return { rate: 'The free plan cannot pay for more.', example: s.upgrade_text ?? 'Upgrade the plan to send more.', canPay: false };
  if (!s.usd_per_unit) return { rate: 'Not billed by use.', example: s.upgrade_text ?? 'Nothing to pay.', canPay: false };
  const per = (n: number, label: string) => `${usd(s.usd_per_unit! * n)} per ${n.toLocaleString('en-US')} ${label}`;
  switch (s.service) {
    case 'workers_ai': return { rate: `About ${per(1000, 'neurons')}.`, example: `Another full day's worth (${s.included.toLocaleString('en-US')} neurons) costs about ${usd(s.usd_per_unit * s.included)}.`, canPay: true };
    case 'images': return { rate: `${per(1000, 'transformations')}.`, example: `100 more photos (about 5 transformations each) cost about ${usd(s.usd_per_unit * 500)}.`, canPay: true };
    case 'workers_requests': return { rate: `${per(1_000_000, 'requests')}.`, example: `So far above the allowance: about ${usd(s.overage_usd)}.`, canPay: false };
    case 'workers_cpu': return { rate: `${per(1_000_000, 'CPU milliseconds')}.`, example: `So far above the allowance: about ${usd(s.overage_usd)}.`, canPay: false };
    case 'claude': return { rate: 'Billed per token by Anthropic, at the prices in Program settings.', example: 'A question costs about US$0.002 to US$0.01 with the default model, so US$1 covers 100 or more.', canPay: true };
    default: return { rate: `${usd(s.usd_per_unit)} per unit.`, example: `So far above the allowance: about ${usd(s.overage_usd)}.`, canPay: false };
  }
}

/** The title of a used-up card: "Included Workers AI used up for today: Allow paid usage". */
export function usedUpTitle(s: Pick<ServiceState, 'label' | 'period'>): string {
  return `Included ${s.label} used up for ${s.period === 'day' ? 'today' : s.period === 'month' ? 'this month' : 'now'}`;
}

/** The value a cap field must have: US$0.01 to US$1,000. Returns the error or null. */
export function capProblem(raw: string): string | null {
  const n = Number(String(raw).replace(/[$,\s]/g, ''));
  if (!raw.trim() || !Number.isFinite(n)) return 'Enter the most it may cost, in US dollars.';
  if (n < 0.01 || n > 1000) return 'Enter an amount from US$0.01 to US$1,000.';
  return null;
}

/** A share in words: 8000 basis points is 80%. */
export const share = (bps: number) => `${Math.round(bps / 100)}%`;
