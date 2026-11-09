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
  assistant: 'Today\'s free AI allowance is used up. The assistant is back at midnight, Toronto time. Everything still works from the screens and pop-ups.',
  assistantClaude: 'The assistant is paused: its Claude budget for today is used (or not allowed yet). An Admin can allow it in Settings > Usage. Everything still works from the screens and pop-ups.',
  copy: 'AI copy waits for tomorrow (daily included usage reached). The template text stays on the page until then.',
  turoEmail: 'Turo emails are read by the rules only until tomorrow (daily included AI usage reached). Emails the rules cannot read wait in the review list.',
  photos: 'Included image transformations are used up for this month: the original photo is used, and the studio background is tried again when the allowance allows.',
  emailsHeld: 'Some emails are waiting: the email plan\'s included emails are used for now. Booking, payment and sign-in emails still go first; the others are sent when the count resets.'
} as const;

/** The pause message of a feature for a gate's state, or null when it may run. */
export function pauseMessage(feature: keyof typeof PAUSE, gate: { ok?: boolean; paused?: boolean; service?: string; message?: unknown } | null | undefined): string | null {
  if (!gate || gate.ok !== false) return null;
  if (feature === 'assistant' && gate.service === 'claude') return PAUSE.assistantClaude;
  // the budget's own words (0133): how much of the day is used and when it is back
  if (feature === 'assistant' && typeof gate.message === 'string' && gate.message) return gate.message;
  return PAUSE[feature];
}

/** US dollars: two decimals, three for a rate under 10 cents (US$0.011). */
export const usd = (n: number | null | undefined) => {
  const v = n ?? 0;
  const small = v > 0 && v < 0.1 && Math.round(v * 100) / 100 !== v;
  return `US$${v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: small ? 3 : 2 })}`;
};

/** What allowing paid usage would cost at the current rates: per unit, a typical day above the allowance, and the cap. */
export function paidCost(s: Pick<ServiceState, 'service' | 'unit' | 'usd_per_unit' | 'included' | 'period' | 'pause_mode' | 'upgrade_text' | 'overage_usd'> & { used?: number }): { rate: string; example: string; canPay: boolean } {
  if (s.pause_mode === 'hold') return { rate: 'The free plan cannot pay for more.', example: s.upgrade_text ?? 'Upgrade the plan to send more.', canPay: false };
  if (!s.usd_per_unit) return { rate: 'Not billed by use.', example: s.upgrade_text ?? 'Nothing to pay.', canPay: false };
  const per = (n: number, label: string) => `${usd(s.usd_per_unit! * n)} per ${n.toLocaleString('en-US')} ${label}`;
  switch (s.service) {
    // a hard stop at the free allowance (0133): never paid
    case 'workers_ai': return { rate: 'Free allowance only: never paid.', example: 'It stops at the included neurons each day and starts again at midnight, Toronto time. The staff assistant keeps its reserved share all day.', canPay: false };
    case 'images': return { rate: `${per(1000, 'transformations')}.`, example: `100 more photos (about 5 transformations each) cost about ${usd(s.usd_per_unit * 500)}.`, canPay: true };
    case 'workers_requests': return { rate: `${per(1_000_000, 'requests')}.`, example: `So far above the allowance: about ${usd(s.overage_usd)}.`, canPay: false };
    case 'workers_cpu': return { rate: `${per(1_000_000, 'CPU milliseconds')}.`, example: `So far above the allowance: about ${usd(s.overage_usd)}.`, canPay: false };
    case 'claude': return { rate: 'Billed per token by Anthropic, at the prices in Program settings.', example: 'A question costs about US$0.002 to US$0.01 with the default model, so US$1 covers 100 or more.', canPay: true };
    // R23 (0229): every text costs about a cent, inside the budget too
    case 'quo_texts': return { rate: `${usd(s.usd_per_unit)} per text.`, example: `This month: ${(s.used ?? 0).toLocaleString('en-US')} texts, about ${usd(s.usd_per_unit * (s.used ?? 0))}.`, canPay: false };
    default: return { rate: `${usd(s.usd_per_unit)} per unit.`, example: `So far above the allowance: about ${usd(s.overage_usd)}.`, canPay: false };
  }
}

/** A service's name without the note in brackets: "Workers AI". */
export const shortLabel = (label: string) => label.replace(/ \(.*\)$/, '');

/** The title of a used-up card: "Included Workers AI used up for today: Allow paid usage". */
export function usedUpTitle(s: Pick<ServiceState, 'label' | 'period'>): string {
  return `Included ${shortLabel(s.label)} used up for ${s.period === 'day' ? 'today' : s.period === 'month' ? 'this month' : 'now'}`;
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

// 0320 (docs/changes/2026-11-06-owner-todo-usage-noise.md): the banner speaks in money. A service billed by use is red only
// when this month's projected cost above the allowance reaches the Program setting (US$5 by default), a quiet note under
// it; hard stops and the email holds keep their banner.
export type BannerTone = 'red' | 'amber' | 'note';
export interface CfEmail { state: 'ok' | 'absent' | 'failing' | 'off'; enabled: boolean; ok_at: string | null; failed_at: string | null; error: string | null; sent_month: number; included: number }
export interface BannerRow { service: string; label: string; share_bps: number; level: 70 | 80 | 100; used_text: string; included_text: string; overage_usd: number;
  resets_at: string | null; tone?: BannerTone; projected_usd?: number | null; red_usd?: number | null; cf?: CfEmail }

/** The tone of a banner row (an older database without 0320: red at 100%, amber before). */
export const bannerTone = (r: Pick<BannerRow, 'tone' | 'level'>): BannerTone => r.tone ?? (r.level === 100 ? 'red' : 'amber');

/** One row in words: "Website CPU time at 123% (36,899,350 of 30,000,000 CPU ms), about US$0.88 above it projected this month". */
export function bannerLine(r: BannerRow): string {
  const base = `${shortLabel(r.label)} at ${(r.share_bps / 100).toFixed(0)}% (${r.used_text} of ${r.included_text})`;
  if (typeof r.projected_usd === 'number') return `${base}, about ${usd(r.projected_usd)} above the allowance projected for this month`;
  return r.overage_usd > 0 ? `${base}, about ${usd(r.overage_usd)} above the allowance so far` : base;
}

/** A quiet note's row, short: "Website CPU time 123% used, about US$0.88 this month". */
export function noteLine(r: BannerRow): string {
  return `${shortLabel(r.label)} ${(r.share_bps / 100).toFixed(0)}% used, about ${usd(r.projected_usd ?? r.overage_usd)} this month`;
}

/** Where the owner sets Cloudflare Email Service up (Settings > Usage, the steps). */
export const CF_EMAIL_STEPS_HREF = '/admin/settings/usage#email-setup';
/** The exact one-time steps (docs/changes/2026-11-03-cloudflare-email.md). */
export const CF_EMAIL_STEPS = [
  'Cloudflare dashboard, the carmacars.ca account: Compute (Workers) > Email Service. Enable it (request access if the page asks).',
  'Add the sending domain carmacars.ca and add every DNS record it shows (SPF include and DKIM). Keep Resend\'s records: both can sign for the domain.',
  'GitHub, the carmacars repository: Settings > Secrets and variables > Actions > Variables. Add CF_EMAIL_BINDING with the value 1.',
  'Run the next production deploy. Its run says "the Worker gets its EMAIL binding"; this page then shows Cloudflare sending.'
] as const;

/** Resend's daily allowance in words: the number from the setting (Program settings, Resend emails a day; the email pace
 * read or the usage row), never a number written here (r35). */
export function resendDay(n: number | string | null | undefined): string {
  if (typeof n === 'number' && Number.isFinite(n) && n > 0) return `${n.toLocaleString('en-US')} a day`;
  if (typeof n === 'string' && n.trim()) return `${n.trim()} a day`;
  return 'your daily email limit';
}

/** Whether Cloudflare sends the emails, in one sentence; null when it does. `resend` is Resend's daily allowance now. */
export function cfEmailSentence(c: CfEmail | null | undefined, resend?: number | string | null): string | null {
  if (!c || c.state === 'ok') return null;
  const r = resendDay(resend);
  if (c.state === 'off') return `Cloudflare Email Service is turned off in Program settings, so every email goes through Resend (${r} included).`;
  if (c.state === 'failing') return `Cloudflare Email Service refused the last emails${c.error ? ` (${c.error})` : ''}, so they went through Resend (${r} included).`;
  return `Cloudflare Email Service is not set up yet, so every email goes through Resend, which includes only ${r}. The one-time setup gives ${c.included.toLocaleString('en-US')} a month.`;
}

/** r35 (0900): the day's emails against the cap in one plain line, with why the cap is that number: Cloudflare's budget
 * counts only while Cloudflare Email Service sends. Every number comes from the email pace read, none is written here. */
export interface EmailBudget { used: number; cap: number; cf_state?: string | null; cf_counted?: boolean | null; cf_budget?: number | null; resend_budget?: number | null }
export function emailBudgetLine(b: EmailBudget): string {
  const n = (x: number) => x.toLocaleString('en-US');
  const head = `${n(b.used)} of ${n(b.cap)} today`;
  if (typeof b.cf_budget !== 'number' || typeof b.resend_budget !== 'number') return `${head}`;
  if (b.cf_counted) return `${head} (Cloudflare ${n(b.cf_budget)} + Resend ${n(b.resend_budget)})`;
  const why = b.cf_state === 'off' ? 'Cloudflare Email Service is turned off in Program settings'
    : b.cf_state === 'failing' ? 'Cloudflare Email Service refused the last emails'
      : 'Cloudflare Email Service is not set up';
  return `${head}: only Resend is sending (${why}, which adds ${n(b.cf_budget)})`;
}

