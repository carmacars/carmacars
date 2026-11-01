// Live chat (0370): what happens when the assistant does not reply, in words for the visitor's hand-over and a note
// for staff. Pure, unit tested (reply-path.test.ts); web/src/server/chat.ts and /api/chat use it.
import type { AgentResult } from './agent.ts';

export const QUOTA_REASON = 'the assistant is off for today (daily included AI usage reached)';

/** A note staff read in the conversation when the assistant failed. */
export const failureNote = (msg: string) => `The assistant could not reply (${msg.replace(/\s+/g, ' ').slice(0, 200)}). Live chat shows "AI replies paused" until a reply works again. Please answer the visitor.`;

/** A note staff read when the assistant did not run for this message (its budget or setting). */
export const pausedNote = (reason: string) => `AI replies paused: ${reason}. Please answer the visitor.`;

/** The hand-over for a result without a reply: the reason staff see, whether it is the day's allowance, and a note when it failed. */
export function handoffFor(r: Pick<AgentResult, 'ok' | 'error' | 'handoff'>): { reason: string; quota: boolean; note: string | null } {
  if (r.error?.startsWith('quota')) return { reason: QUOTA_REASON, quota: true, note: pausedNote('today\'s free AI allowance for live chat is used') };
  if (!r.ok) return { reason: r.handoff?.reason ?? 'the assistant is not available', quota: false, note: failureNote(r.error ?? 'no answer from the model') };
  return { reason: r.handoff?.reason ?? 'the assistant handed over', quota: false, note: null };
}

/** Why the database did not let the assistant answer this message (server_chat_visitor_message's ai_reason). */
export function notAnsweredFor(st: { ai_reason?: string | null; reason?: string | null }): { reason: string; budget: boolean; note: string } | null {
  if (st.ai_reason === 'budget') return { reason: QUOTA_REASON, budget: true, note: pausedNote(st.reason ?? 'the live share of today\'s free AI allowance is used') };
  if (st.ai_reason === 'max_replies') return { reason: 'a long conversation for the assistant', budget: false, note: 'The assistant reached its replies for one chat (Settings > Program). Please take over.' };
  return null;
}
