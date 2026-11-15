// r48 (2971): fewer texts, more email. The channel of each message type (Program settings), in plain words. Pure, so the
// card and the unit tests share it (model.test.ts).
export type Channel = 'text' | 'email' | 'both';
export interface PolicyType { code: string; label: string; audience: string; urgent: boolean; channel: Channel; chosen: boolean; default: Channel; texts_30d: number; editable: boolean }
export interface PolicyList { production_ready: boolean; types: PolicyType[]; fixed: Array<{ code: string; texts_30d: number }> }

export const CHANNEL_WORDS: Record<Channel, string> = {
  email: 'Email only (a text only when there is no email or it bounced)',
  text: 'Text only',
  both: 'Text and email (the person chooses)'
};
export const CHANNEL_OPTIONS: Array<[string, string]> = [['email', CHANNEL_WORDS.email], ['both', CHANNEL_WORDS.both], ['text', CHANNEL_WORDS.text]];

const FIXED_WORDS: Record<string, string> = {
  deposit_link: 'Deposit link', signin_code: 'Sign-in codes', sign_in: 'Sign-in codes', otp: 'Sign-in codes', staff_alert: 'Staff alerts', staff: 'Texts to staff',
  compose: 'Texts typed by staff', notify: 'Notifications', booking: 'Booking texts', recruit: 'Hiring texts'
};
/** A text sent outside the notifications (it always stays a text), by its kind. */
export const fixedLabel = (code: string) => FIXED_WORDS[code] ?? code.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase());

/** What the row says now: the channel in force, and why (the default, or an Admin's choice). Off: as before. */
export function policyNow(t: PolicyType, ready: boolean): string {
  if (!ready) return 'As before: the person\'s own choice (email is not ready for production yet)';
  return `${CHANNEL_WORDS[t.channel]}${t.chosen ? ' (changed)' : t.urgent ? ' (urgent: keeps the text)' : ' (default)'}`;
}

/** The texts of the last 30 days the defaults would save: the types that go by email only once email is ready. */
export function textsSaved(l: PolicyList): number {
  return l.types.filter((t) => t.channel === 'email').reduce((a, t) => a + (Number(t.texts_30d) || 0), 0);
}
