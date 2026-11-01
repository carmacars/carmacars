# Live chat: the assistant answers, the counts and alerts are right, chats close when the visitor leaves (0370, 0371)

The owner: "the live chat numbers / alerts seem to be broken", "live chats should auto close if theyre not on the
website anymore then whats the point of us responding unless they gave us their number or email?" and "why isnt the
ai chat assistant responding to live chats at all?"

## 1. Why the assistant did not answer

Found in the code. Settings > Usage on November 1 showed no "Visitor live chat" row for 7 days: every model call
(and every failed one) is recorded there, so the visitor messages never reached the model.

- **Live chat had no share of its own.** Since 0133 the staff assistant kept 70% of the 10,000 free neurons, and live
  features got 10,000 less 7,000 less everything background work used (guide upkeep after each deploy, search copy,
  and the neurons Cloudflare counts that the app did not record, counted as background). Background often went past
  3,000, so live chat's room was 0 and every message went straight to a person: no model call, nothing recorded.
- **A chat handed to a person never ended.** Only the assistant's own chats closed (after 12 hours). The same browser's
  next chat continued the old one, still waiting for a person, so the assistant never answered that visitor again.
- **Too expensive a reply.** Every step sent the whole fleet to Llama 3.3 70B: about 250 neurons a step and up to three
  steps, so the share ran out after a few chats.
- **Hand-overs without a reason.** A visitor writing "a person", "manager" or "legal" (as in "a car for a person under
  25" or "the legal age") went to a person without asking the model.
- **Failures were swallowed.** An error became "the assistant is not available" in the hand-over, a log line, and nothing
  on any screen.

Checked and not the cause: the Worker has its AI binding (`wrangler.jsonc`), the deploy writes `LLM_PROVIDER=workers-ai`,
`/api/chat` passes the bot shield, the CPU guard and CSP, and the trigger path is the visitor's own send (the reply is
written in the same request, no cron or queue).

## 2. What changed

- **AI budget (Settings > Usage, Change the shares).** Live features (visitor chat, the phone line, the readers) have
  their own share, `ai_live_bps`, 50% by default, that background work never uses. The staff assistant keeps 30%
  (was 70%), background 10%. Empty live share: the 0133 rule (what the assistant does not keep). Still a hard stop at
  the free allowance.
- **Cheaper replies.** Live chat's model is Llama 3.1 8B (`@cf/meta/llama-3.1-8b-instruct-fp8-fast`, about a sixth of the
  neurons). It has no JSON mode: the reply is read from its text, and when it wrote no JSON object the 70B model (JSON
  mode) is asked once. The prompt lists 12 cars (the page's car and the cars named first, then the cheapest of each
  class) and says how many there are; the visitor can still ask for any car through `search_cars`. 300 output tokens,
  12 seconds a step.
- **Answers from the facts.** A short question about one topic (deposit, age and licence, how booking works,
  cancellation, hours, delivery) is answered from the database's facts with no model call and no neurons. Prices still
  come only from the fleet, quote and search data.
- **Contact early.** The first answer to a visitor without a phone or email asks for one. A phone or email typed into
  a message is kept on the chat (and its lead), as the contact box does.
- **AI replies on** in every settings row. Hand-over words narrowed: "a person" or "manager" alone, and "legal" alone, no
  longer hand over; "talk to a person", "speak with the manager", "legal advice" still do.
- **Failures are visible.** The conversation gets a note only staff see ("The assistant could not reply (...)", "AI
  replies paused: ..."), the failure is recorded under Visitor live chat, and Live chat shows "AI replies paused:
  <reason>" (turned off, the day's live share used, or the last reply failed) until a reply works again. Production
  without the AI binding says so instead of answering with the stand-in.

## 3. Counts and alerts

- **The bug:** the menu counted every chat with status "waiting", for ever (the inbox listed only the last 3 days), and
  never a chat a person had where the visitor wrote again. The alert email went once per chat, only while someone was
  on shift and had ticked "Email me"; the desktop alert fired once per chat per page load.
- **Now:** a chat needs a reply when it waits for a person, or a person has it and the visitor wrote last. The menu
  badge (`chat_counts`), the inbox and the page title count exactly these; follow-ups and closed chats never count.
- One alert per new visitor message waiting for staff (`staff_chat_message`, in-app and the phone alerts topic
  Messages): to the person on the chat, otherwise every Admin, customer service and Sales account, on shift or not.
  Someone replying, the chat closing or becoming a follow-up marks its alerts read, so their pushes are not sent late.
  The desktop alert fires once per new waiting message. The "a chat waits" email is unchanged.

## 4. Auto-close

- Every minute (`app.job_chat_auto_close`): a visitor not seen for `chat_auto_close_minutes` (10, Settings > Program)
  has left. Seen means a heartbeat of their visit, their browser polling the chat, or a message.
- No phone or email (on the chat or their renter account): the chat closes, "Visitor left, no contact", its task is
  cancelled, it leaves the counts and its alerts clear.
- A phone or email and at least one message: it stays open as **Follow up by text/email**, out of the counts, with a
  task of that name in customer service's queue (or the assistant's booking request task for Sales when there is one).
- The visitor comes back (their browser polls the chat, or they open the chat again): it opens again where it was, with
  a staff note.

## Tests

- DB: `supabase/tests/99_live_chat_autoclose.sql` (the live share, the gate's reason and "AI replies paused", staff
  notes the visitor never sees, the counts, one alert per message and to the person on the chat, read on reply,
  auto-close, the follow-up and its task, reopening). `85_ai_budget_assistant_tools.sql` checks the new defaults and
  keeps testing 0133's tiers; `07_notifications.sql` and `99_push_alerts.sql` count the new in-app notice.
- Unit: `web/src/features/chat/reply-path.test.ts` (the reply path with the fake AI provider, the contact question,
  answers from the facts, the shorter context, escalation words, the small model's JSON and its 70B retry),
  `guardrails.test.ts`.

## Guides

- `admin/live-visitors-and-live-chat`: the count, the alerts, "When the visitor leaves", "When the assistant does not
  answer", the settings.
- `va/live-visitors-and-live-chat`: the count, the alerts, follow-ups and closing, "AI replies paused".
