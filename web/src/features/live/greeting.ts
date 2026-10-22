// The chat greeting (migration 0100): where it may open, and when. Pure functions (no browser) so they are unit tested;
// the database answers the words for the page (public.chat_greeting) and refuses the same pages again.

/** Never in the portals, sign-in, booking, checkout, pay or sign pages. */
const NO_GREET = /^\/(account|owner|admin|va|field|investor|partner|portal|staff|sign|sign-in|sign-document|create-account|reset-password|update-password|two-step|choose-portal|read-only|link-expired|guide-pdf|files|d|r|auth|book|my-request|continue|checkout|pay|payment)(\/|$)/;
const PAYSIGN = /\/(pay|payment|sign|checkout)(\/|$)/;
export const greetingAllowed = (path: string) => !NO_GREET.test(path) && !PAYSIGN.test(path);

/** How long until the greeting opens (ms from now): its seconds counted from the visit's first page; null when it
 *  never opens in this visit (off, shown already, a chat going, the chat open). */
export function greetingWait(a: { after: number; start: number; now: number; done?: boolean; chatting?: boolean }): number | null {
  if (!(a.after > 0) || a.done || a.chatting) return null;
  return Math.max(0, a.start + a.after * 1000 - a.now);
}
