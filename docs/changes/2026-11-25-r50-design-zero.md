# The owner's design rules on every page: zero breaches (Release 50)

The check `web/tests/lint/design-rules.mjs` reported 167 known breaches in `design-rules.baseline.json` (117 motion over
300 ms, 27 solid hex borders, 23 linear easings). All are fixed and the baseline is empty (`{}`), so any new breach fails
`npm run lint`.

## What changed

- **Motion 300 ms or less, with the kit's eases**: page and step entrances, reveals, images arriving, toasts, alerts,
  dialogs, the phone-number box, the booking estimate, the portal hero and tiles, the Admin board, the live map's cards
  and feed, the done ticks and progress fills, and the moments (sent, confirmed, offer, signed, review, tier; `MOMENT_MS`
  1150 to 600). The tokens follow: `--t-3` 280 ms, `--t-4` 300 ms. The discount games keep their suspense in the pauses
  between moves, each move 300 ms or less (coin flip and capsule drop timers follow). The renter step tracker's bar
  fill (`StepTracker.tsx`) is 300 ms.
- **No linear easing on UI**: scroll-driven reveals and parallax (hero, photo depth, wipes, lines) use `--ease-out` or
  `--ease-in-out`; the academy and interview meter bars ease out; the rolling die and the shaking box ease in and out.
- **Removed**: two endless decorative drifts that could not be 300 ms (the academy stage's background drift, the portal
  next-step card's glow). Attention pulses (a late calendar item, an overdue wait, a jump target) play a few short
  pulses instead of forever.
- **Alpha borders**: hex borders became `--k-border`, `--k-border-strong`, `--k-border-on-dark` or a colour token for
  drawn outlines (the games' cartoon strokes, the printed guide's phone and incident cards). Google's sign-in button keeps
  its #747775 outline as `rgb(0 0 0 / 0.545)`.
- **`design-allow` only where it belongs**: spinners, progress and countdown bars, shimmer skeletons, the holo card's foil
  shimmer, and the live status lights (live pill, call dot, live-map dot and HQ ping, recording light, the wallboard
  ticker), each with its reason.
- **New tokens** `--ui-ok-on-ink` and `--ui-warn-on-ink` (tokens.css; the portal's `--pu-ok-on-ink` and
  `--pu-warn-on-ink` now point at them), so pages outside the portals use the same success and warning colours on black.

### The R50 screens against the definition of done (rules 9 to 18)

- **Guide me**: the menu grows from its button (`mo-pop-in`) and clears the phone's notch; menu rows 44px with a pressed
  state and hover only with a mouse; the card's close button gets a 44px hit area (`k-hit`) and a pressed state; tokens
  for its sizes, radii and colours.
- **Calls and townhall**: the side tabs hover only with a mouse and press; the chat field is 16px; counts in tabular
  numbers; Join shows busy (`aria-busy`); the interview call page has its loading skeleton.
- **e-Transfer and card-paused copy buttons**: the copy icon swaps to a check with the kit's blur (`IconSwap`); 44px under
  a finger.
- **Owner stages, check-ins, investor library, What's new**: alpha borders, token radii and sizes, 44px checkbox and script
  rows, dates, days and kilometres in tabular numbers.
- **Report a bug** (the floating copy): hover only with a mouse, a pressed state, 44px under a finger.
- **Book choice**: the turned-off option's hover only with a mouse. **Pull to refresh**: the kit's durations and eases,
  the safe area at the top. **Reimbursements** (My shifts): the inline font size became a token class.
- **Academy visuals** and the **earnings calculator**: hard-coded colours, font sizes and radii replaced with tokens
  (red, greys, success and warning on black, `--fs-*`, `--r-*`); `h4` headlines are balanced like `h1` to `h3`.

## Guides

No guide change: the look and timing of motion and borders changed, no screen's steps.
