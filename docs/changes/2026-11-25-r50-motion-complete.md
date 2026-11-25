# Every micro-interaction, on every page and portal (Release 50)

The owner (November 25): "There were other animation ideas we had discussed, like the button presses and the confirmation
thingies and error nudges and a BUNCH more shit like that that I've forgotten." This release audits the whole list from
`2026-11-20-r48-motion-covers-filters.md` (sections 4 and 4b), `docs/style-guide.md` ("Release 49: the reels' polish pass")
and `docs/blueprint/00-overview.md` (section 11), adds what a premium app has on top, and makes each one real and wired
everywhere it applies: the public site, the renter, owner and investor portals, the Admin, the staff and VA portal, the
field portal and the store app's shell.

Rules kept: every UI move 300 ms or less, eases or springs (never linear), hover only on `(hover: hover)` with a fine
pointer, transform and opacity, nothing on screen at first paint moved, and nothing moves under the system's reduced
motion setting or the footer's **Pause animations** control (an error is then colour and focus only; a success is the word
and the tick, still).

Code: `web/src/portable/motion/interact.ts` (new: the feedback runtime), `feedback.ts` (new: pure words, unit tested in
`feedback.test.ts`), `feedback.css` (new), `runtime.ts` (starts the feedback, wider success ticks), CarmaCars' settings in
`web/src/styles/motion-kit.css` and `MOTION_HOOKS` (root layout). Small hooks: `RouteProgress.tsx` (announces server
requests), `lib/forms/guard-dom.ts` (nudge and inline validation), `features/admin/Act.tsx` (Act and SaveForm),
`Effects.tsx` (car card to car page), the toasts, `PullToRefresh.tsx` and `AppShell.tsx` (haptics), the app's `ui/kit.tsx`.
Test: `web/tests/e2e/r50-motion.spec.ts`.

## The audit

Status: **present** (was there and works), **added** (new in this release), **fixed** (was there but broken or against
the rules). Counts at the end.

### 1. Button presses

| Item | Before | Now |
| --- | --- | --- |
| Press scale with a spring back on every button, `[role=button]` and `.mo-press` card | present (motion.css, r48) | present |
| Press highlight (ripple) on `.mo-ripple` | present | present |
| Busy state on a form sent to a server action (BrandLoader's `aria-busy` ring) | present (RouteProgress), but only for `<form action>` forms | **fixed**: every button whose press starts a server request now shows it (interact.ts, from RouteProgress's `mo:action` events); Act and SaveForm set `aria-busy` themselves |
| Success morph: the button shows a tick and "Saved", "Sent", "Done" for 1.5 s, then returns | missing | **added** (`moResult`, `[data-mo-result="ok"]`); Act, SaveForm explicitly; every other finishing button (Save, Send, Sign, Pay, Approve, Add, Update, Copy...) by itself; Next, Search, Sign in never morph |
| Failure: the button rings in the error colour and nudges | missing | **added** (`[data-mo-result="error"]`, a new alert on the page after the answer) |

### 2. Confirmations

| Item | Before | Now |
| --- | --- | --- |
| Success tick on a status line (`[data-mo-saved]`, `SuccessTick`) | present for "Saved" only | **fixed**: any finished status ("Saved.", "Sent", "Done.", "Refund sent.", "Link copied"; `isSuccessText`), so Act's inline "Done." and the portal forms' lines get it |
| Act dialogs: the opening button confirms after the dialog closes | missing | **added** |
| Toasts slide in (site, Admin, moments) | present | present |
| Undo in a toast where the server can take it back | missing | **added**: `toast(msg, ms, { undo })` and `adminToast(msg, tone, ms, { run })`; wired to Money's "Not a booking" (put aside, Undo puts it back). Renter merges already had their Undo button |
| Copy to clipboard: "Copied" with the icon swap | partly (each copy button its own words) | **added** centrally: any `navigator.clipboard.writeText` from a press morphs that button to a tick and "Copied" |

### 3. Error nudges

| Item | Before | Now |
| --- | --- | --- |
| First invalid field shakes on an invalid submit (4 oscillations, 280 ms) | partly (`.field.has-error` only, 380 ms) | **added** for every form: the form guard nudges the field it focuses; any field turned `aria-invalid` within 4 s of a press nudges (the first of its form) |
| Focus moves to the first invalid field | present (form guard) | present |
| The error message fades in under the field | present (`.error`, `.alert` drop-in) | present |
| A server error nudges the form's button and shows the inline error | missing | **added** (interact.ts after `mo:action` end) |
| A PIN or sign-in code shakes on a wrong code | missing | **added** (`autocomplete="one-time-code"` fields: two-step, phone sign-in, e-sign, phone gate) |
| Reduced motion: no shake, colour and focus only | n/a | **added** (`mo-shake` only applied when motion is allowed) |

### 4. Inputs

| Item | Before | Now |
| --- | --- | --- |
| Focus rings (keyboard focus) | present | present |
| Inline validation as a field is left: a wrong value is marked with its message at once | missing (only after a submit) | **added** (guard-dom: on leaving an edited field the browser's check refuses; empty required fields still wait for the submit) |
| A tick in a field left with a valid value that has a rule | missing | **added** (`[data-mo-valid]`) |
| Checkbox and radio pop; switch slide | present | present |
| A stepper's counter rolls when it changes | missing | **added** (`.fd-stepper__n`, `.pu-stepper output`, `[data-mo-bump]`) |

### 5. Numbers

| Item | Before | Now |
| --- | --- | --- |
| Dashboard figures count up once in view | present, but `AnimatedNumber` ran 1.1 s, `data-count` up to 1.4 s | **fixed**: both 300 ms |
| A price that changes animates (dates or add-ons changed) | present for the estimate total (`Tween`, 380 ms, ignored the Pause control) | **fixed** (280 ms, honours Pause) and **added** a roll on every other total and price (`.pt-total`, the booking bar, the offer total, gift cards) |
| Tabular numbers | present on tables, badges, money | **added** on every counted, rolled or totalled figure |

### 6. Navigation

| Item | Before | Now |
| --- | --- | --- |
| The tab pill slides | present | present |
| View Transitions between pages (cross-document and in-app links, a short fade) | present (Effects, motion.css) | present |
| Shared element: the car card's photo grows into the car page's first photo | missing | **added** (`mo-car-hero`, 280 ms) |
| The route progress bar | present | present |
| Skeleton to content fades | partly (`page-enter` after a link) | **added** for streamed parts (a loading boundary's skeleton replaced: the content fades in) |

### 7. Lists

| Item | Before | Now |
| --- | --- | --- |
| New rows stagger in on public lists only | present | present |
| A row being removed collapses smoothly | missing | **added** (a row pressed and then removed, one or two at once: its ghost collapses in 250 ms; a list replaced does not) |
| Dragged items lift | partly (shadow on the extras order) | **added** scale lift (`.is-dragging`, `[aria-grabbed]`, the extras order) |

### 8. Overlays

| Item | Before | Now |
| --- | --- | --- |
| Dialogs, menus and details grow from where they were opened | present | present |
| A bottom sheet on a phone with drag to dismiss | partly (some sheets slide up; no drag) | **added**: on a phone (40rem or less) the Admin, portal and site dialogs are bottom sheets with a handle; any modal dialog and the portals' sheets follow a drag down and close past 90 px or a flick |
| The backdrop fades | missing | **added** |

### 9. Haptics in the app

| Item | Before | Now |
| --- | --- | --- |
| Haptics through the native bridge (`haptic()` exists in `lib/native/bridge.ts`) | present on a few app actions | **added**: every success morph, error nudge and sheet closed by a drag (`mo:feedback`, AppShell) |
| Pull to refresh | browser vibration only | **added**: the app's haptic tap |
| The native app: field errors | colour only | **added**: shake and the error haptic (`ui/kit.tsx` `useNudge`) |

### 10. Empty and success states

| Item | Before | Now |
| --- | --- | --- |
| An empty state that appears: its icon pops in once | missing | **added** (portals' and site's empty states; not the Admin's daily lists) |
| Big moments (booking confirmed, request sent, signed) | present (Moment, burst) | present |
| The native app's empty state | static | **added** (Appear) |

### 11. Hover lift

| Item | Before | Now |
| --- | --- | --- |
| Card links lift on fine pointers only | present (`pt-card`, `hub-card`, `pu-stat--link`, `pu-tile`) | **added** the portals' action tiles (`pu-action`); the car cards are r50-cards' |

### Counts

- **Present** (kept, checked working): 19
- **Added**: 27
- **Fixed**: 5 (busy state on every request, success ticks beyond "Saved", the two count-ups over 300 ms, the estimate total's tween)

Known and left to their owners this release: the car card's swipe, hover and drive-off (r50-cards).

## Porting to the Almash builds

The portable kit (`web/src/portable/motion/`, no brand, no framework in the runtime) now carries:

- `tokens.css`, `motion.css`, `design.css` as before, plus `feedback.css` (morph, shake, valid tick, roll, collapse,
  appear, backdrop, drag lift). A brand sets `--mo-ok`, `--mo-err`, `--mo-focus`, `--mo-accent`.
- `runtime.ts` `startMotion(hooks)` now also starts `interact.ts` `startFeedback`; hooks gain `bumps` (figures that roll),
  `empties` (empty states) and `sheets` (sheets that close with a drag). `moResult(button, ok, word?)` and `nudge(el)` are
  exported for components that know the answer.
- The build's side, three small pieces: dispatch `window` `mo:action` `{phase: 'start' | 'end'}` around each server
  request (CarmaCars: the fetch wrapper in `RouteProgress.tsx`); dispatch `mo:nudge` (bubbling) on the field its form
  validation focuses; listen to `mo:feedback` `{kind}` for haptics in a native shell. Mark a button the component answers
  itself with `data-mo-explicit`.
- `feedback.ts` (pure, tested): `doneWord`, `isSuccessText`, `isRemoval`, `SHAKE_MS`.

## Guides

No guide change: the controls work as before; only how they answer a press changed.
