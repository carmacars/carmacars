# One answer per booking request (0177)

The owner: "Make sure that multiple sales people and staff can't send an offer back for the same request." And: new
requests go to Admin, customer service and fleet first; commission-only staff (the Sales function) may claim or answer a
request only once it has gone unanswered for a while, and after that it is never Sales' alone.

## The single answer (server-enforced)
- Every staff answer to a request goes through `app.request_answer_guard` in the transaction of the answer: send the
  offer, decline, ask the renter, and the changes to an offer that is out (Edit the offer, Send again, Withdraw,
  Renter approved by phone). It locks the booking row (`select ... for update`), so two people answering at the same
  moment wait for each other; the second finds the request answered and is refused: "Already answered by Ada Admin at
  Tue, Oct 27 at 9:14 am: open the offer to see it." (a decline: "open the booking to see it"). Decline racing an offer
  and a question racing an offer are refused the same way.
- A change to an offer that is out carries the version the screen showed (`expected_version`); a screen showing an older
  version is refused: "Changed by <name> at <time> (now version 3): open the offer to see it."
- `app.send_offer` itself refuses a request someone else is answering, whatever calls it.

## The claim ("I'm answering this")
- Opening a request to answer it (its Review and offer tab, Admin or customer service and Sales assistants) takes it:
  `request_claims`, live for `program_settings.request_claim_minutes` (new, 20 by default, 5 to 240), renewed every
  minute while the person works (typing, clicking), ended by sending, declining or leaving the page.
- Everyone else sees "Being answered by <name> since <time>" on the booking (the answer buttons are off), on Bookings >
  Requests (with Assigned), on the assistants' Requests and To do (Waiting for a reply) and on Admin > Today's "Answer
  <renter>'s request" line (its button becomes Open).
- Take over: an Admin at any time (Take over on the booking); anyone once the claim ran out (opening the request takes
  it). Each takeover is on the booking history: "Taken over from Val Cs (by an Admin)" or "(their claim had run out at
  9:31 am)".
- The request's task goes to the person answering it (in progress) and back to its queue when they leave without
  answering: never two people on it.
- Commission and "sourced" rules are unchanged: the first offer sent still credits its sender.

## Sales wait for customer service first
- A request from the website (not one staff entered) is answered by Admins, customer service and fleet for its first
  `program_settings.request_sales_after_minutes` (new, 15 by default, 0 to 1440; 0 opens it to Sales at once). Until then
  the Sales function (and field staff) cannot claim, send, decline or ask on it: their list says "Opens to you at
  3:15 pm" and the booking page "Open to Sales at 3:15 pm if nobody answers. Customer service answers it first."
  Everyone else sees "Open to Sales at 3:15 pm if nobody answers."
- After the wait it is open to Sales and stays open to everyone else: whoever claims first holds it; an active claim
  blocks everyone but an Admin's takeover; a claim that ran out can be taken by anyone. A claim that ran out does not
  restart the wait.
- When a request opens to Sales with nobody on it, a Sales task says so ("Answer Riley Renter's request for ...: open to
  Sales now"; `app.job_requests_open_to_sales`, every 5 minutes; once per request; done when it is answered).

## Settings
Settings > Program > Booking requests and offers: "the person answering a request holds it for (minutes)" and "Sales may
answer a request this many minutes after it came in".

## Tests
- `supabase/tests/99_offer_claims.sql`: two staff racing (two connections with dblink), decline against offer, stale
  edits, claim expiry and takeover, Admin takeover, renew and release, the task, the lists and Today, the Sales wait and
  task, after the wait customer service still claims an unclaimed request but not one Sales hold, an Admin can; the
  privileges.
- `web/tests/e2e/offer-claims.spec.ts` (375 and 1440, axe), `web/src/features/offers/claim.test.ts`.

## Guides
- `admin/requests-offers-and-bookings`: opening a request takes it, Take over, a second answer refused, the Sales wait.
- `va/customer-service`: the claim, the buttons off while someone else answers, "Opens to you at" for Sales.
