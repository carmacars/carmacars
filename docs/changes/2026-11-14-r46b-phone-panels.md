# Pop-ups and the top row fit a phone (Release 46, part B)

The owner: "on mobile a bunch of things don't show up properly, like What's new and Report a bug; the text goes off the sides".

- **The cause**: on a phone the Admin portal's top row has six equal buttons of about 50 px, with labels kept on one line. "What's new" and "Report a bug", the two longest, ran past their buttons, over their neighbours and off the side. Each label now wraps onto a second line inside its button (`styles/admin-ui.css`).
- **One shared net for every pop-up** (`styles/core.css`): a dialog never passes the browser's own limit less a landscape notch (the safe area), a long word or link wraps instead of running past the sides in every dialog, sheet, popover, toast, the bell's and assistant's panels, the caller pop-up, the voice dock and the game, and a dialog placed in a portal's top row (What's new, Report a bug) starts again from the body's type instead of the row's small one-line type.
- **What's new**: the sheet's side padding keeps clear of a notch. **Report a bug** and every Admin dialog: less padding under 480 px and a height that follows the visible screen (`dvh`), so Send and Cancel stay reachable.
- **Tests**: `tests/e2e/phone-panels.spec.ts` opens What's new, Report a bug and the assistant at 375 and 320 px in the Admin, staff and renter portals and fails on any label past its button or anything in a pop-up past either side (`panelFits`, `labelsInButtons` in `tests/e2e/helpers.ts`; a modal dialog never widens the page, so the page check alone could not see it). `whats-new.spec.ts` checks its pop-up the same way.

## Guides

No guide change: no step or button changes, only how the words fit a phone.
