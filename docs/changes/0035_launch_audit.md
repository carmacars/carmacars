# 0035: what the launch audit changed in the database

Migration `supabase/migrations/0035_launch_audit.sql`, tests `supabase/tests/22_launch_audit.sql`. The audit itself is
`docs/audit/2026-10-13-launch-audit.md`.

## What was added or changed

| Part | Why | Built |
| --- | --- | --- |
| Sample cars kept out of search | The 20 cars the seed put on the live site are placeholders until the owner enters the real fleet; their pages were indexable and in the sitemap, so search engines would learn stand-in photos and made-up cars | `vehicles.is_sample` (default false), set on the 20 seeded cars (the sample owner's cars with the seed's VINs) and by `scripts/seed.mjs` on every new seed. `app.public_car_page` says `indexable: false` for a sample (the page sends `noindex, follow` and no canonical); `app.public_model_hub` is indexable while one of its cars is real; `app.public_sitemap` leaves out sample cars and model pages of samples only; `app.public_listing_row` carries `is_sample`. A sample car still shows on the fleet page and takes requests. `app.site_setup_problems` lists the sample cars on Admin > Today. An Admin clears the flag on the vehicle's Listing tab ("Not a sample", `admin_do` action `vehicle_sample`, audited as `set_sample_car`) |
| Review publishing needs consent | 0034 recorded the renter's consent to publish but an Admin could still publish a review without it | `admin_do` refuses `review_publish` when `reviews.publish_consent_at` is empty; the Publish button is shown only with the consent |
| Marketing waits for the mailing address | The anti-spam law requires the sender's mailing address in every commercial email; production has none yet (0025 item 8, 0034 not done) | `app.outbox_claim` (0018's kept as `app.outbox_claim_0018`) first moves marketing rows to `delayed`, "waiting for the mailing address (Admin > Settings > Site)", retried every hour, while `site_settings.mailing_address` is empty |
| Owner FAQ on tracker fees | 0029: the first and last month's Insurance Fee is billed on its own and the Tracker Install Fee only once the tracker is installed; the seeded FAQ said both are paid before the car goes live | The two FAQ blocks are updated where an Admin has not edited them (the seed file says the same) |
| Email wording | Read at 375 and 640 px by the audit | `app.notification_payload` (0034's kept as `app.ntf_payload_0034`): "Our team" when no field staff member is assigned (it opens a heading); "1 new damage item" or "2 new damage items" instead of "item(s)"; the monthly owner invoice says how to pay ("From the invoice page, with your saved method ending 6621") instead of "Debited from account ending ----", because the debit on the 15th is not automated (0029, not done); the payout email names the payout account's last four digits, not the fee payment method's |

## Tests

`22_launch_audit.sql` (26 assertions): a car is not a sample unless marked; a sample car page is not indexable and
says so; a real car stays indexable; a sample is still on the fleet page; sample cars and model pages of samples only
are out of the sitemap, a model page with one real car stays in it; Admin > Today lists the samples; an Admin clears
the flag, the car and its model page enter the sitemap, the change is audited; an assistant and a browser cannot; the
0030 actions still work behind the new ones; a review without consent cannot be published, one with consent is;
without the mailing address only the transactional email is claimed and the marketing one waits an hour with its
reason, and goes once the address is entered; a browser cannot run the sender.

## Not done

- The monthly pre-authorized debit on the 15th (charging the saved method off-session) and the debit-results job
  (0029). Owners pay each monthly invoice from its page; the email now says so.
- A staff proposal to change a confirmed booking still sends the renter no email of its own (0024 item 1).
