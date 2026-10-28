# Sales on a website request: the renter's contact, why the buttons are off, and the offer sent when it opens

The owner, October 28, 2026: an in-person Sales person opening a booking request from the website "is unable to click any
buttons at all", cannot see the renter's phone or email to call them, and cannot send an offer.

## What was found

- The database lets an in-person Sales assistant with a $0 single limit save and send an ordinary offer at the rate sheet
  price once the request is open to them (suite 99 offer claims, section 6b). The single limit is checked only where money
  moves (a payment recorded another way, a refund, a card charge above what is open), never on an offer: it stays as it is.
- The buttons were off (`inert`) in two cases, by design since 0177: during the Sales wait (a website request goes to
  customer service first, 15 minutes by default, Program settings), and while someone else holds the request (an Admin or
  customer service who opened it to answer it holds it 20 minutes, renewed while they work). Off buttons looked exactly like
  live ones, and the reason was a single line above the tabs, far from the buttons (off screen on a phone).
- A page opened during the wait, or while someone else held the request, did not take the request when it opened: it only
  looked again every 30 seconds, and never claimed it for the person who opened it to answer it.
- The renter's phone and email were in the page's data for customer service and Sales but not shown on "The request as sent".

## What changed

- Booking page (assistant), Review and offer: "The request as sent" shows the renter's **Phone** (a tel: link, to call from
  the phone) and **Email** (a mailto: link).
- Booking page (assistant and Admin), Review and offer: when the answer buttons are off, a note right above them says why
  and when they come on: "It opens to you at 3:15 pm if nobody has answered it: the buttons come on by themselves then" or
  "Ada Admin is answering this request. Their claim runs out at 3:40 pm unless they keep working on it ... If it cannot wait,
  ask an Admin to take it over" (an Admin gets Take over there). Off buttons are shown grey.
- The page looks again the moment the request opens (the end of the wait, or when the other person's claim runs out), so
  the buttons come on then without a reload; the first touch or key on the page takes the request for the person who opened
  it to answer it (a page left alone never takes it, so nobody holds a request without working on it).
- No database change: the claim of someone who stopped working already runs out after Program settings > Booking requests
  (20 minutes by default; an Admin may lower it to 5).

Tests: suite 99 offer claims (section 6b), web/src/features/offers/claim.test.ts, tests/e2e/sales-request-offer.spec.ts.

## Guides
No guide change: the assistant guide (customer service, Answer a request) already says a request someone else holds opens
when their claim runs out or an Admin takes it over, and that Sales see "Opens to you at" during the wait; the steps are the
same, the page now says it beside the buttons.
