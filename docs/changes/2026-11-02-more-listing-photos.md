# More listing photos (hotfix, migration 0432)

The owner had 20 good photos per car, but a listing could not be submitted until all 14 required angles were added, and only 6 extra photos fit.

- **Submit with what you have:** the "Submit for listing" button is enabled as soon as one photo is added. The server already accepted this since 0070 ("Submitted without: ..." note, sample photos stand in for missing angles). Missing angles stay listed under the button as "Can be added later".
- **Other detail** holds up to 20 photos (was 6).
- **More outside photos** (new optional shot, up to 20): extra exterior angles that get the studio background like the required outside angles.

## Guides

- `field/photo-shoots` (the crash page changes no guide steps)

## Crashes in the browser (migration 0433)

A visitor reported the request form crashing near the end; nothing was logged, because a crash in the browser never reaches the server and the site had no error page of its own. Now:

- **Our own error page** (`app/error.tsx`, `app/global-error.tsx`) instead of a blank screen: "Try again" (forms keep what was typed) or reload.
- **Every crash is reported** (`/api/client-error`, and window error and promise listeners in the root layout) to `client_errors` (30 days, service role only), and the first of each kind in a day opens an Admin task "Website crash on <page>: <error>" with the browser, so a broken step is found the same day.
