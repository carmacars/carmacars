# CarmaCars: what is still open

Everything else on the website, in the emails and in the database is confirmed (the owner's answers of October 8, 2026, migration 0025). These are the only items still missing. Each one is a single field: send the value and it changes everywhere.

| # | Item | Shown now | Where it is used | Needed from you |
| --- | --- | --- | --- | --- |
| 1 | Street address and mailing address | Hatched "to be added" | Contact page, footer (appears when set), privacy policy (Privacy Officer address), marketing opt-in line on the request form, the footer of every email | The street address to show, and the mailing address if it is different. Marketing emails should not go out until the mailing address is in (`app.site_setup_problems()` reports it) |
| 2 | Logo and favicon | Text wordmark "CarmaCars"; a drawn stand-in favicon | Header, footer, emails, browser tab | The logo file (SVG, plus a version for black backgrounds). The favicon is then made from it |
| 3 | HST number | Not shown | Receipts and statements | The HST registration number |
| 4 | Holding company names and location | Not shown | Owner title agreements and registration paperwork | The legal names of the holding companies and where they are registered |
| 5 | Field staff pay | Not set | Staff portal, field job payouts | The pay per handover, delivery or job for field staff |
| 6 | GPS tracker documents | Not attached | Owner onboarding, tracker install | The tracker supplier's documents: device specification, installation guide and data terms |
| 7 | Real car list and photos | 20 sample cars with drawn stand-in photos | Fleet, car pages, home, request form | The real cars (year, make, model, trim, colour, fleet number, classes, rates, deposit tier, kilometres a day, overage rate, delivery fee) and 8 photos per car, following the shot list in `PHOTOS.md` |
| 8 | Delivery rate per kilometre and company location | Delivery shows the car's fee "plus distance, priced in your offer" | Car pages, delivery page, estimates, request form | The rate per kilometre, and the coordinates of the location distance is measured from |
| 9 | Airport surcharge amounts | "An airport surcharge may apply" | Car pages, delivery page, request form, FAQ | The surcharge for Toronto Pearson and for Billy Bishop (or none) |
| 10 | Coverage default prices | "Priced in your offer" | Estimates, request form, requirements | Default prices for coverage sold through CarmaCars, by car or class and driver age, per day or per booking |
| 11 | Google place id for reviews | Google reviews block shows its empty state; the profile link is hatched | Home page reviews | The Google Business Profile place id |
| 12 | Privacy Officer name | Hatched "Name to be added" (the email, privacy@carmacars.ca, is filled in) | Privacy policy | The Privacy Officer's name. The same policy has one more hatched blank: the countries outside Canada, other than the United States, where remote staff work |
| 13 | ServiceOntario forms and a toll statement | Not attached | Owner registry visit preparation; toll invoice import | The four ServiceOntario form PDFs used for the registration change, and one sample toll statement file (for example a 407 ETR statement) to build the import against |

## Please confirm the phone number

The number given for the phone, WhatsApp and the 24-hour roadside and incident line is **289-321-5991**, and that is what the site and every email now show. Your other business number is **647-573-3377**. They differ by one digit (575 and 573). Please confirm 289-321-5991 is correct, or send the right one.
