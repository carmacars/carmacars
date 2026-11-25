# Academy: each joke answer is written for its own question (Release 50: 4720)

Migration `4720_r50_question_jokes.sql` (its generated block comes from `supabase/seed/4200_gen_academy.mjs`), data `web/src/features/academy/jokes-by-question.json`, tests `web/src/features/academy/r50.test.ts` and `supabase/tests/99_academy_jokes.sql`.

## What changed

- **About one question in three carries a joke** (122 of 407), and only where a light, obviously wrong answer to that very question fits. Serious questions carry none: safety, legal, money, ID, damage and insurance.
- **Each joke is written for its question**: `jokes-by-question.json` is keyed by `"<section slug>:<sort>"`, with the question's prompt and its joke (90 characters at most, never mean, never about people or groups). The generator writes it into the migration as `app.academy_question_joke_line(key, prompt)`, which matches the prompt by md5, so a reworded question loses a joke written for its old wording.
- **No shared bank any more**: the 4200 trigger `app.academy_questions_joke()` now takes out every 4200 bank joke and the question's last joke on each save, then adds the question's own line if it has one, at a pseudo-random place, moving the right answer's index with it. A new question, or one with no line, gets no joke. No Admin To do. `academy_questions.joke` names the joke option (or null).
- **The right answers are unchanged**: the right answer points at the same option text before and after (checked on all 407 questions).
- **Quiz and editor**: `academy_quiz_start` returns `questions[].joke`, the shown position of the joke, and the quiz shows a "Nice try." line only when that option was picked. The Admin editor marks the joke from `academy_content`'s `joke` and edits the real options only; the joke comes back by itself on save.
- **Adding a joke later**: add a line to the JSON, run `node supabase/seed/4200_gen_academy.mjs`, and put the regenerated `academy_question_joke_line` function in a new migration followed by `update academy_questions set options = options` (4720 itself is already applied in production).

## Porting to the Almash builds' academies

Each Almash build with an academy carrying the same question table (`academy_sections`, `academy_questions` with `options` jsonb and `answer` int):

1. **Column**: `alter table academy_questions add column if not exists joke text;`
2. **Jokes file**: export that build's questions (`select s.slug || ':' || q.sort, q.prompt, q.options ->> q.answer from academy_questions q join academy_sections s on s.id = q.section_id`), then write a joke only for the questions where one fits (about one in three, none on safety, legal, money, ID, damage or insurance), in the brand's own voice, into that build's `jokes-by-question.json` in the same shape `{ "<slug>:<sort>": { "prompt": "...", "joke": "..." } }`.
3. **Generator**: copy the QUESTION JOKES part of `4200_gen_academy.mjs` (the checks, the md5 of the prompt and the `academy_question_joke_line` block). Without a 4200-style bank, drop the bank from the trigger's strip list (`v_strip` starts empty).
4. **Migration**: copy `4720_r50_question_jokes.sql` under that build's next free number: the column, the generated function (revoke from public, grant execute to service_role), the trigger function and trigger, `update academy_questions set options = options`, and the `joke` key in its quiz start and admin read functions (adapt to that build's own versions of those functions; keep `search_path` ending in `pg_temp`).
5. **Front end**: the `joke` field on the quiz start type, the playful line when the shown joke is picked (`ownJokeQuip`), and the editor marking `o === q.joke` and editing the real options only.
6. **Tests**: copy `99_academy_jokes.sql` sections 1 and 2 (0 or 1 joke, the question's own line, no bank, right answers unchanged, no fallback for a new question) and the 4720 tests of `r50.test.ts`; point the quiz test at a section of that build that has jokes.
7. Regenerate that build's `types.ts` (the new column) and set its schema marker to its highest migration.

## Guides

No guide change: the Academy quizzes changed content, not a screen or workflow a guide describes.
