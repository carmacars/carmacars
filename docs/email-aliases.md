# CarmaCars email addresses

Every address the platform uses. Values live in `site_settings` and `email_aliases` (migration 0025), `prototype/tools/src/site.mjs` and `emails/src/brand.mjs`.

## Sending addresses (carmacars.ca)

Sent by Resend from the `carmacars.ca` subdomain. No mailbox is needed: nobody signs in to these, and replies go to the reply-to alias of each email, never to the sender. The display name is "CarmaCars", except the insurance emails (below).

| Address | Used for |
| --- | --- |
| `bookings@carmacars.ca` | Renter booking emails: requests, offers, agreements, pickup, return, incidents |
| `owners@carmacars.ca` | Owner emails: application, agreements, vehicles, bookings on their cars |
| `billing@carmacars.ca` | Money emails: receipts, charges, refunds, invoices, statements, payouts, investor payments |
| `hello@carmacars.ca` | Account emails (sign-in, password, security), marketing (review requests, come-back offers) and general staff notices |
| `blindspotcarrental@carmacars.ca` | Insurance emails, display name "Blind Spot Car Rental" (migration 0187): the insurer invoice, Email the adjuster, and Email the renter on an insurer-billed booking when Blind Spot Car Rental is chosen as the sender. Replies come back to the same address |

Staff notices go out from whichever of the four fits their subject (a payment failure from billing, a new request from bookings).

Resend needs the domain verified (SPF, DKIM and a DMARC record on `carmacars.ca`) before launch.

## Receiving aliases (carmacars.ca)

Create each one in Google Workspace as an alias of `rent@carmacars.ca`, so everything lands in the one mailbox the team already reads. Filter or label by the "To" address to route work to the right person.

| Alias | What it is for |
| --- | --- |
| `contact@carmacars.ca` | The public address on the site and in every email footer; replies to account and marketing emails and to staff notices |
| `bookings@carmacars.ca` | Replies to renter booking emails, and booking changes or cancellations sent by email |
| `owners@carmacars.ca` | Replies to owner emails and questions from people who want to list a car |
| `billing@carmacars.ca` | Replies about charges, receipts, refunds, invoices, statements and payouts |
| `privacy@carmacars.ca` | Personal information requests to the Privacy Officer, and replies to account security notices |
| `investors@carmacars.ca` | Replies to investor emails; questions from existing investors (shown only on the investor sign-in page) |
| `blindspotcarrental@carmacars.ca` | Replies from insurers, adjusters and renters to the Blind Spot Car Rental insurance emails. **Create it** (an alias of `rent@carmacars.ca`, or its own mailbox) before the insurance emails go out, or replies to them bounce |

Because the sending addresses are on carmacars.ca itself, also create `hello@carmacars.ca` as an alias of `rent@carmacars.ca` so a reply sent straight to a sender address still arrives (bookings@, owners@ and billing@ are already in the list above).

`info@carmacars.ca` is retired and is used nowhere.
