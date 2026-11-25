# CarmaCars: read first

This file is read at the start of every Claude Code session and by every helper in this repo. The engineering rules are in docs/engineering-rules.md, the definition of done in docs/blueprint/00-overview.md section 11 and the design rules in docs/style-guide.md: follow them. Output is final, not a brainstorm.

## Working rules (Nov 25: what makes the biggest difference)

1. **Read once, edit once, test once.** Before changing anything, list every file the change needs and read them in one pass. Then make all the edits, then run the checks once. No read, edit, read, edit loops.
2. **Every request is a queue.** A new instruction or correction mid-task joins the end of the queue; it never makes the work in hand disappear. Stop only when every item in the queue is done or explicitly handed back.
3. **A mistake is a gap in the instructions.** No apologies. Name the gap (this file, a brief, a doc, a missing test) and add the line or test that prevents it next time.
4. **You aren't gonna need it.** Build what was asked, at the quality the definition of done sets; no speculative layers, settings or abstractions. Scope ideas go in the report as suggestions, not into the code. Prefer the simplest design that works; after finishing, re-read the diff and cut anything that crept in.
5. **Fact check before claiming.** Before writing "we do X", "we don't have X" or "X is fixed", open the code and cite file:line, or run the query or test that shows it. Never answer from memory of an earlier read.
6. **Do not guess.** If a fact is unknown, look it up or say it is unknown. Never invent a value, a field name, an API shape or a result.
7. **Fresh-eyes review.** For anything touching money, security, migrations or more than a few files, a separate cheap-model reviewer with only the diff and the brief checks it for bugs and unintended changes before it merges.
8. **Say the next action.** Every status update ends with the one next action being taken, so the owner can redirect early.
9. **Plain, short, active.** Brief reports in plain active English (Simplified Technical English); no filler, no "load-bearing", no narration of steps. No em dash characters in code, comments, commit messages or site copy; use a colon, a comma or two sentences.
10. **Be honest, not agreeable.** Challenge a plan or an assumption when the evidence says it is wrong, say the cost of a shortcut, and never soften a result (a failed check is reported as failed).
