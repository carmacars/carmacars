# The AI interview: instant hire for Sales only, video answers, scores out of 10, a stricter pass (Release 43: 2672, 2680, 2695)

Migrations `2672_r42_hotfix_auto_hire_sales_only.sql`, `2680_r43_hiring_rules.sql`, `2695_r43_stricter_ai_interview.sql`.

## What changed

| Part | What changed |
| --- | --- |
| Who is hired by itself | Only a Sales applicant who passes. Every other role that passes (customer service, fleet, finance, field) is invited to book an interview date; the interview slots before the weekly townhall open for every role that is not Sales |
| Answers | Video only. Nothing is typed, and the English question is spoken too; the server refuses a typed answer |
| Scores | Every answer is scored out of 10 with a one-line reason, kept with the interview beside the topic scores and the score out of 100 |
| Pass rule | The score at the bar (80), no knock-out answer, answers averaging 7 or more, none under 5, and spoken English good or fluent. An interview scored before the per-answer scores keeps the old rule |
| Redo | Admin button **Redo the AI interview** on the candidate: staff access ends if active, the old interview and answers are kept as history, the application goes back to Invited with a new 7 day interview link by email |

## Guides

- `admin/hiring`: the video-only answers, the scores out of 10, the stricter pass rule, interview dates for every role but Sales, and Redo the AI interview
- `va/fleet`: field applicants book an interview date
