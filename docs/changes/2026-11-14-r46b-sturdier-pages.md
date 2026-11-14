# Four crashes from the error log (Release 46, part B)

From `client_errors`, each fixed at its cause:

- **Admin > Field jobs, React error 418** (the page drawn by the server did not match the browser's). The work lists of the day (a part redrawn in the browser) wrote each time with Intl's own words: "9:00 a.m." has a narrow no-break space on the server's ICU and a plain space in Chrome. `clockText` and `dayText` (`features/field-portal/model.ts`) now use only Intl's numbers (`lib/clock.ts`, as r35 did for Visitors) and our own words: "9:05 AM", "Sat, Nov 14". Unit tested.
- **Staff > Game leads, React error 441** (the server could not finish the page): of the page's three reads, the discount game leads were the only one with no fallback, so when that read failed (the database busy, as the 441s of November 6) the whole page failed. On a fresh database the read answers for Sales and customer service alike, so the cause is the missing fallback: the page (and Admin > Renters > Leads, which reads the same) now shows the new leads and the contacts, and says the game leads did not load.
- **The pay link (/pay/...) on Android Chrome, "Failed to execute 'removeChild' on 'Node'"**: Chrome translates a page by itself and puts its own elements in place of React's text, and Stripe's card box held a React child (the loading line) that Stripe's mount and React both touched. The pay forms (pay link, checkout, add-ons) are kept out of translation (`translate="no"`: amounts, Working, the messages) and Stripe's box holds no React child (the loading line lies over it).
- **Checkout, "Server Action ... was not found on the server" after a deploy**: a page of the previous build calling an action the new one does not have. Next 16 words it this way; the stale page guard and the error page knew only the older words. The page now reloads once, fresh, wherever the error is met: the error page (not reported as a crash when it reloads), the guard in the page's head, any uncaught error or promise (`Listener`), the renter portal's actions (`useAct`) and the payment forms' first call. At most once a minute per tab, so an outage never loops (`lib/client-error/recover.ts`, `reloadIfStale`). Unit tested.

## Guides

No guide change: nothing a person does changes.
