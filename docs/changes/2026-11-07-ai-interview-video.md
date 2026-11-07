# AI interviews on video (release 30, D1, migration 0585)

Branch `r30`. SCHEMA_MARKER 0585. The remote assistant applicants' AI interview (0380) records each answer as a short video
with sound, not the voice alone.

## What changed

- **The applicant** (`web/src/features/careers/Interview.tsx`): the consent names the video; a camera and microphone
  check comes before the first question (the live preview and a sound level), and when the browser cannot record it says
  why in plain words (blocked, no camera or microphone found, in use by another app, a browser without video recording).
  Each question is shown and read aloud; the answer time starts once it has been read (at once without speech) and counts
  down in view, red for the last 15 seconds. The applicant presses **Record** whenever ready inside it; recording stops by
  itself at 0:00 and the answer is sent. Retakes as the setting allows (none by default). Only without a camera or a
  microphone are the answers typed, on the same clock (what is typed goes at 0:00). A question whose time ran out with
  nothing said is kept as "No answer: the time ran out." (mode `none`, never a follow-up; the scoring reads it as no answer).
- **Recording**: one camera and microphone stream for the whole interview; per answer two MediaRecorders, the video with
  sound (Safari and iOS `video/mp4`, Chrome and Firefox `video/webm`, about 720p at 24 fps, 1 Mbps) and its audio track
  alone (`audio/mp4` or `audio/webm`), which the transcript and the scores are made from, as before.
- **Storage**: the browser uploads both straight to the private documents bucket on signed links of 15 minutes
  (`prepare` on `/api/careers/interview/[token]`, keys `hiring/interviews/<interview>/<n>-<id>-v.webm|mp4` and
  `<n>-<id>.webm|m4a|ogg`), then sends the answer with the two keys; the server reads the audio track for the transcript.
  On R2 a video is written as it arrives and served by byte range (`/api/storage`), never whole in memory; 60 MB at most.
- **Settings** (Admin > People > Hiring, Roles and links, AI interviews card, **Interview settings**): Answer time (1 to 3
  minutes, 2 by default, `hiring_ai_answer_seconds`), Retakes allowed (0 to 3, none by default, `hiring_ai_retakes`), Keep
  interview videos (`hiring_ai_video_days`, 90 days by default). The interviews job deletes the videos after it (and with
  a removed application); the sound, the transcript and the scores stay for the application's 12 months.
- **Staff review** (Admin > Hiring > the candidate, AI interview card): each answer's video inline (a signed link of an
  hour), its transcript and the AI's score for the rubric line it speaks to; **Watch all** plays every answer in order.
  Hiring is an Admin task: no staff role has the Hiring pages.
- **Consent and privacy**: the consent text and the privacy policy (live copy where it still has our words, and
  `docs/source/website_terms_policies.md`) name the video and the 90 days.
- Tests: `supabase/tests/99_ai_interview_video.sql`, `web/src/features/careers/ai-interview.test.ts`, and
  `tests/e2e/r27-ai-interviews.spec.ts` in a Chrome with a fake camera and microphone: the check, answers recorded and
  uploaded, one left to run out (red, stopped at 0:00, sent), the Admin's videos (a byte range), Watch all and the settings.

## Guides

- `admin/hiring`

Published by migration 0585 (`supabase/seed/0585_gen_guides.mjs`), the guide block of release 30.
