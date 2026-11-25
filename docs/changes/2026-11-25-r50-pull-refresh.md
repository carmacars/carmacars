# Pull to refresh in the app (Release 50)

Component `web/src/features/pull-refresh/PullToRefresh.tsx` (mounted in the root layout), maths `model.ts`, test `model.test.ts`.

## What changed

- **Drag down from the top to refresh** in the CarmaCars app (`<html data-shell="app">`, whose body turns the bounce off) and in the site added to a phone's home screen (display mode standalone). A phone browser keeps its own pull to refresh, so nothing is added there.
- **Refreshes in place**: the page's data is fetched again (`router.refresh`); forms, open tabs and the scroll stay. A round mark follows the finger from under the header, fills as the pull reaches the trigger, and spins while the page refreshes; screen readers hear "Refreshing".
- **Never by accident**: touch only, one finger, a vertical drag that starts at the very top of the page, not inside a dialog, the open menu, a field or a scrolled inner list (`data-no-ptr` opts an area out).

## Guides

No guide change: it is the phone's usual gesture and needs no steps.
