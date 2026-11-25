# Book instantly or Request to book; Report a bug over any pop-up (3900)

Migration `3900_r50_book_choice.sql`. The owner (Nov 24): customers choose Instant Book or Request to book; "Report a bug" must be clickable while a popup, modal, drawer, sheet or dialog is open, on every portal.

## Book instantly or Request to book

- **One instant system.** Who may book at once is still `app.instant_book_check` (1304, 2421: Gold Rewards, licence verified, not blocked or taken away, no damage, claim or money owing, the Program setting on). A request becomes an instant booking only through `public.server_instant_book` (the car free, a standard rental billed to the renter, the licence gate). Nothing about eligibility changes.
- **The choice.** The car page's estimate and the booking form's last step show two options, **Request to book** (the default, as before: no charge, staff approve, then a pay link or an offer) and **Book instantly** (pay now, confirmed at the website price). Book instantly is closed, with the reason, for a renter who may not book at once, for an example car, and for dates the car shows taken or cannot do. The car page carries the choice to the form as `?how=instant`; the button reads **Book instantly** or **Request to book**, the sticky bar too.
- **Cards off.** With card payments paused (`app.card_payments_state`), Book instantly says it is paid by Interac e-Transfer; Sign and pay already shows the e-Transfer box (3650).
- **Recorded.** `bookings.book_choice` (`instant` or `request`; null for bookings staff made and older ones) and `bookings.book_choice_note` (why Book instantly became a request). The bookings audit trigger logs both. `app.book_choice` / `public.server_book_choice` records it right after the request: a visitor's own fresh request (request only), or the signed-in renter's. The first choice stands.
- **Booked at once.** The renter goes to Sign and pay; the "We have your request" email and its text, still queued, are skipped (the confirmation follows payment as before).
- **Sent as a request.** The request stays in the staff queue (Admin, Sales, customer service) with its usual To do and notifications; the renter gets the usual CarmaCars "We have your request" email and text and sees **Sent as a request** on the request page. Staff see the chip **Asked to book instantly** on the booking with the reason (`app.request_history` carries the choice).
- **Car page cost.** The car page asks the server only on a device whose renter could book instantly (the `cc-instant` hint, set by the renter home and the booking form); everyone else gets no extra call.

## Report a bug over any pop-up

- While a native modal dialog is open (everything outside it is inert), a copy of the button is rendered inside that dialog (the top layer); for any other pop-up (`aria-modal`, or a dialog or drawer covering the header's button, or the button made inert) it is rendered at the end of the page above everything. It sits at the bottom left. The app lock (a security screen) is left alone.
- The form itself is rendered at the end of the page and opened as a modal on top, so no pop-up's `inert` or focus trap reaches it.
- The picture shows a modal dialog where it was, above a dimmed page; the report's context carries `popup` (kind, title, test id of each open pop-up), cleaned on the server like the other facts.

## Tests

- DB: `supabase/tests/99_r50_book_choice.sql`.
- Unit: `web/src/features/booking/book-choice.test.ts`, `web/src/features/bug-report/logs.test.ts`.
- e2e: `web/tests/e2e/bug-report-over-popup.spec.ts` (What's new open, Report a bug pressed inside it, the report names it).

## Guides

- `renter/find-a-car-and-send-a-request`: Book instantly or Request to book.
- `admin/requests-offers-and-bookings`: Book instantly or Request to book; Asked to book instantly.
- `admin/bug-reports`: the button over an open pop-up.
- `va/customer-service`: Asked to book instantly.
- `va/start-here`: Report a bug with a pop-up open.
