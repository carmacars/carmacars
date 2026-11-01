# AI interviews for the remote assistant roles, everything recorded (0380, 0381)

The owner, Release 27: "wants to explore AI interviewing VAs with everything recorded". Remote assistant applicants who
pass screening now take a short recorded interview on their own, from a link, instead of a live call. The AI asks, records,
transcribes, scores and recommends; an Admin decides. On by default.

- **Who:** the remote assistant roles (`hiring_roles.remote` and `staff_kind = 'va'`): Customer service, Fleet operations,
  Finance and billing, Remote sales. A candidate who passes screening, or whom an Admin presses **Invite anyway** for,
  gets one email, `applicant_ai_interview` ("Start my interview"), instead of the booking link. The in-person roles (Field
  staff, Sales in person) keep their phone calls. No texts and no reminders: the one email. The link works 7 days
  (`hiring_ai_interview_days`). The setting: `program_settings.hiring_ai_interviews`, on; **People** > **Hiring**, Roles
  and links, card "AI interviews for the remote roles", **Turn off** / **Turn on**.
- **The page:** carmacars.ca/careers/interview/ and the candidate's personal key (no sign-in). First the consent line, with
  a link to the privacy policy and "I agree to the recording"; nothing is recorded before it, and the consent and its exact
  words are kept with the interview. Then one question at a time: shown, and read aloud by the browser (speechSynthesis;
  **Play the question** again). **Record my answer** records the microphone (MediaRecorder: webm/opus, or mp4 on Safari;
  2:30 at most), **Stop**, listen back, **Send this answer** or **Record again**. **Type my answer instead** on every
  question (and always on a browser that cannot record, or when the microphone is blocked). The candidate can leave and
  come back with the same link. The booking link of such a candidate opens the interview, and the application form's
  last step says "Start my interview". The words "test" and "exam" are never used.
- **The questions** (`app.ai_interview_questions`, built from the role, nine): the last job (experience, English); the
  role's skills (its own question for customer service, fleet, finance and sales); social media work; what CarmaCars does
  and a normal shift; the role's scenario from its call guide; the role's schedule and pay, for a yes; internet and
  backup; education, studies and other jobs; career or job, and moving to Canada. Together they cover the VA rubric.
- **Follow-ups:** after an answer to a question, the model (Workers AI, Llama 3.3) reads it and, when it is vague, asks one
  short follow-up (at most 25 words; never after a follow-up; at most 2 an interview, `hiring_ai_followups`). An answer of
  70 words or more is never followed up (no call). When the model cannot be asked, an answer under 15 words gets a plain
  follow-up. A follow-up that says "test" or "exam" is dropped.
- **Recorded:** the audio of each answer in the private documents bucket (`hiring/interviews/<interview>/<n>-<random>.<ext>`),
  saved before the answer is recorded; the transcript (Workers AI Whisper, `@cf/openai/whisper-large-v3-turbo`, English,
  `hiring_ai_transcribe_model`); every question as asked, in order (`ai_interview_answers`); then the AI's result
  (`ai_interviews.result`): each rubric topic scored 1 to 5 with a quote from the answers (a quote the candidate did not
  say is dropped by the database), the spoken English (fluent, good or basic, a score and a note), red flags, a summary,
  and a recommendation: **Invite to a live call**, **Hire**, **Decline** or **Good fit for Sales instead** (never Sales
  instead for the Sales role). The interview score of 100 uses the topic weights; moving to Canada is noted, never scored.
- **The AI never decides:** the last answer makes the application **Interviewed**; Hiring says "N AI interviews done and
  waiting for your decision". The candidate page has the AI interview card (the recommendation and scores, then each
  answer: play the recording, read the transcript) and the rubric with "AI interview: recommends ... You decide." The
  Admin decides with the rubric's Decision and **Emails to send** (0226), or presses **Invite to a live call** (the
  booking link for a video call, which waits for an interview day as any invitation does), or **New interview link** for
  an expired one (7 more days, the answers kept).
- **The AI budget (0133), a hard stop, no paid usage:** transcripts and follow-ups are live work (someone is waiting),
  the scores background work. Settings > Usage lists "Hiring interviews: transcripts", "follow-up questions", "scores and
  recommendation". An answer that cannot be transcribed now (the share used, an error) is kept: the interviews job
  (`/api/jobs/interviews`, from the Worker's tick when `server_jobs_due.interviews`) transcribes it later, then scores the
  interview (one a run; the allowance used: an hour later, not counted as an attempt; 5 failures stop it).
- **Privacy:** Admins only (row-level security, server-only functions). The interview goes with the application's personal
  data, 12 months after the decision for a candidate not hired (0173): the transcripts, questions, quotes, result and
  consent text in the database, the audio files from storage (the interviews job). The privacy policy (`legal.privacy`,
  where it still has our text, and docs/source/website_terms_policies.md) gains a row "Recorded interviews (remote
  assistant roles)" (the audio, the transcript and the AI summary, with consent first; Cloudflare Workers AI processes
  the speech on our behalf; a person decides) and the retention row names the recordings. Last updated: November 7, 2026.
- **For the owner's lawyer:** the consent line on the interview page (`app.ai_interview_consent_text`), the new privacy
  policy row and the retention row, and whether recording candidates in the Philippines (Data Privacy Act of 2012) needs
  more than this consent, for example a named data protection contact. Flagged for review; the text is live as written.

Files: `supabase/migrations/0380_ai_interviews.sql`, `supabase/migrations/0381_ai_interview_guides.sql`,
`emails/src/emails/applicant_ai_interview.mjs`, `web/src/features/careers/ai-interview.ts` (prompts, follow-up rule, fake
model), `web/src/features/careers/Interview.tsx`, `web/src/features/careers/admin/AiInterview.tsx`,
`web/src/server/interviews.ts`, `web/src/integrations/transcribe/`, `web/src/app/careers/interview/[token]/page.tsx`,
`web/src/app/api/careers/interview/[token]/route.ts`, `web/src/app/api/jobs/interviews/route.ts`. The storage route now
serves the recordings as audio with byte ranges (Safari). Tests: `supabase/tests/99_ai_interviews.sql`,
`web/src/features/careers/ai-interview.test.ts`, `web/tests/e2e/r27-ai-interviews.spec.ts` (fake AI and fake speech to text).

## Guides

- `admin/hiring`: AI interviews for the remote roles; what happens to each application.
