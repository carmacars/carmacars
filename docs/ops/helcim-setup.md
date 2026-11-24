# Helcim setup (release 50)

Stripe closed the account, so card payments run on Helcim. Until the two keys below are set, the site takes no cards
(the card processor stays **off**) and renters pay by Interac e-Transfer. Nothing else needs a code change.

## 1. The API token (HELCIM_API_TOKEN)

1. Sign in to Helcim. Open **All Tools**, then **Integrations**, then **API Access Configurations**.
2. Press **New API Access**. Name it `CarmaCars website`.
3. Access levels: **General: Read & Write**, **Transaction Processing: Admin** (purchase, preauth, capture, refund and reverse), **Customers: Read & Write**.
4. **HelcimPay.js allowed domains** (the card window only opens on these): add `carmacars.ca` and `www.carmacars.ca`.
5. Save, then copy the **API token** it shows. It is shown once.

## 2. The webhook (HELCIM_WEBHOOK_VERIFIER_TOKEN)

1. **All Tools**, **Integrations**, **Webhooks**. Turn **Webhooks** on.
2. **Deliver URL**, paste exactly: `https://carmacars.ca/api/webhooks/helcim`
3. Tick **Card Transaction**. Save.
4. Copy the **Verifier Token** shown on the same page.

## 3. Put the keys on the server

In the Cloudflare Worker's settings (Variables and Secrets), as **secrets**, never in the code or the repository:

| Name | Value |
| --- | --- |
| `PAYMENTS_PROVIDER` | `helcim` |
| `HELCIM_API_TOKEN` | the API token from step 1 |
| `HELCIM_WEBHOOK_VERIFIER_TOKEN` | the verifier token from step 2 |
| `HELCIM_TERMINAL_ID` | optional: only if Helcim support gives you a terminal id other than the default CAD one |

The site reads them on the next request; no deploy is needed for a change of key.

## 4. Check it works

- Connector: `helcim_account` says `connected: true` and `webhook_verifier_set: true`.
- Make a $1.00 pay link on a test booking, pay it with a real card, then refund it from the booking's Money tab. `helcim_find_payments` lists the purchase and the refund.

## What runs where

- **Card forms** (Sign and pay, pay links, the offer pay box, add-ons, gift cards, owner invoices by card) open Helcim's own card window (HelcimPay.js). CarmaCars never sees the card number.
- **Deposits** are Helcim preauthorizations. Helcim holds them **7 days**. For a rental of 7 days or less the deposit is a hold, released or captured as before (the Re-authorize To do comes before it lapses). For a longer rental the deposit is **charged and refunded at release**; the pay page and the booking's Money tab say so.
- **Card on File** (tolls, incidentals, the deposit on pickup day) uses the card token Helcim saves with the first payment.
- **Refunds** go back to the card through Helcim (a full refund the same day is a reverse, with no fee).
- **Stripe** stays selectable (`PAYMENTS_PROVIDER=stripe` with `STRIPE_SECRET_KEY`) if the account is restored. Old Stripe payments stay on the bookings; refund those in the Stripe dashboard or by e-Transfer.
- **Not on Helcim**: owners' pre-authorized bank debits (owners pay invoices by card or e-Transfer) and the Stripe card readers (take the card on Helcim's terminal, then record it with `helcim_record_paid`).
- Helcim does not say whether a Visa or Mastercard is a debit card; only Interac and Helcim's debit card types count as debit. A Visa Debit passes the credit card check.
