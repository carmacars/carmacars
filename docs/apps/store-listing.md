# The CarmaCars app: store listing drafts

Drafts for App Store Connect and Play Console (docs/apps/publish.md, step 7.5). The texts themselves are files, one per
field, in the layout the stores' upload tools use, checked against each store's limits on every push
(apps/carmacars/scripts/check-app.mjs):

| Field | App Store (apps/carmacars/store/ios/en-CA) | Google Play (apps/carmacars/store/android/en-CA) |
| --- | --- | --- |
| Name | `name.txt`: CarmaCars (30 max) | `title.txt`: CarmaCars: Car Rental (30 max) |
| Subtitle / short description | `subtitle.txt`: Car rental across Ontario (30 max) | `short_description.txt` (80 max) |
| Description | `description.txt` (4000 max) | `full_description.txt` (4000 max) |
| Keywords | `keywords.txt` (100 max, commas, no spaces) | none (Google reads the description) |
| Promotional text | `promotional_text.txt` (170 max, changeable without review) | none |
| What's new | `release_notes.txt` | `changelogs/1.txt` |
| Links | `privacy_url.txt`, `support_url.txt`, `marketing_url.txt` | Privacy policy: https://carmacars.ca/privacy |
| Graphics | Icon comes from the build | `store/android/play-icon-512.png`, `store/android/feature-graphic.png` |

Category: **Travel** (App Store primary; secondary **Business**), **Travel & Local** (Google Play). Price: free. No
in-app purchases: rentals are real-world services paid by card through Stripe, which both stores allow outside their
billing (App Store guideline 3.1.3(e), Google Play's payments policy for physical goods and services).

## One app, every role (the split)

One app, **CarmaCars**, on both stores, as decision 0002 says. The signed-in person's role opens their portal: renter,
car owner, investor, staff, field staff, Admin. Why not separate apps:

- Apple's guideline 4.3 (spam) refuses several apps that are the same site in different wrappers, and guideline 2.1
  expects every app to be reviewable by the public; a staff-only app would need Apple's Business Manager distribution.
- One listing gathers every rating and review, and one set of keys, Firebase project and review.
- People with two roles (an owner who also rents, staff who rent) use one app and one sign-in.
- The site already sends each person to their portal (/app, /choose-portal), so the app adds nothing per role.

The listing leads with renting; owners and staff are one paragraph. The investor portal is reachable for existing
investors but the listing does not advertise investing (both stores review apps that promote investments as financial
services, which would need licensing declarations).

## Privacy: App Store "App Privacy" answers

Data used to track you: **No** (no advertising or cross-app tracking; no App Tracking Transparency prompt needed).
Everything below is **linked to the person** and used for **App Functionality** only (plus **Customer Support** where
marked). Nothing is used for third-party advertising.

| Apple category | Data type | Why |
| --- | --- | --- |
| Contact Info | Name, Email Address, Phone Number, Physical Address | Account, bookings, agreements, delivery; support |
| Financial Info | Payment Info | Card payments and deposits (Stripe processes them; we keep the brand and last four digits) |
| Financial Info | Other Financial Info | Owners' payout account; investors' bank account (owner and investor portals) |
| Location | Precise Location | Recorded with a signature and with pickup and return photos, only when the person allows it |
| Sensitive Info | (none) | |
| User Content | Photos or Videos | Licence, selfie, coverage proof, condition photos |
| User Content | Customer Support, Other User Content | Messages to our team; signatures and requests |
| Identifiers | User ID | The account |
| Identifiers | Device ID | The push alerts address of the device (only when alerts are turned on) |
| Purchases | Purchase History | Bookings and receipts |
| Usage Data | Product Interaction | Pages visited on the site, for support and fraud prevention (kept 13 months) |
| Other Data | Other Data Types | Driver's licence details (number, class, expiry) and date of birth, for the rental agreement and insurance |

Face ID and fingerprints never leave the phone (the phone answers yes or no); they are not collected.

## Privacy: Google Play "Data safety" answers

- Collects data: **Yes**. Shares data: **Yes**, only with service providers that process it for us (payments: Stripe;
  email: Resend; texts: Quo; push: Firebase), which Google counts as not shared when they act for us. Answer **No** for
  sharing if the form offers the "service provider" exemption, which it does.
- Encrypted in transit: **Yes**. People can ask to delete their data: **Yes** (Profile, **Delete my account**, and
  https://carmacars.ca/privacy). Independent security review: **No**.
- Types (all **collected**, **required** for an account except where optional, purpose **App functionality** and
  **Account management**; **Fraud prevention** for the licence and selfie): Personal info (name, email, phone, address,
  other info: date of birth and licence details), Financial info (payment info, other: payout account), Location
  (precise, optional), Photos (licence, selfie, car photos), Messages (to our team), App activity (page views),
  App info and performance (crash logs: **No** unless a crash reporter is added), Device or other IDs (push address,
  optional).

## Age rating

App Store: answer **None** to every content question; **Unrestricted web access: No** (the app opens only carmacars.ca
and Stripe; other links open the browser). Result **4+**. Google Play (IARC questionnaire): category **Utility,
Productivity, Communication or Other**; no violence, sexuality, language, controlled substances, gambling; users interact:
**Yes** (messages with our team, not between users); shares location: **No** (it is recorded for the booking, not shown
to other users); digital purchases: **No**. Result **Everyone**. Target audience: **18 and over**.

## Screenshots plan

Make them from the guides workflow's real screens (.github/workflows/guides.yml) on the staging site, with example.test
renters, in the app's own frame: black status bar, no browser bar. Required sizes: **iPhone 6.9"** (1320 x 2868; Apple
scales it for the smaller iPhones) and **Android phone** (1080 x 1920 or larger, 9:16). The app is iPhone only, so no iPad
set. Six screens, the same on both stores, each with one short caption above the screen (white on black, the red rule):

1. **Find your car**: Cars, a filtered list with photos and prices. Caption: "Every car, with real prices."
2. **Request in a minute**: the request form with dates and delivery. Caption: "Send a request. Pay nothing yet."
3. **A person sends your offer**: the offer page with the total. Caption: "A real offer from our team."
4. **Sign and pay in the app**: the rental agreement's signature step. Caption: "Sign and pay on your phone."
5. **Licence and pickup photos**: the licence card with the camera button, then a condition photo. Caption: "Your licence
   and car photos, with the camera."
6. **Alerts at every step**: the lock screen with a CarmaCars alert ("Your offer is ready") over the Trips page.
   Caption: "Alerts for offers, pickups and messages."

A 15 to 30 second preview video is optional (App Store app previews, a YouTube link on Google Play); skip it for the
first release.

## Review notes (paste into App Store Connect, "App Review Information", and Play Console, "App access")

> CarmaCars is a car rental company in Ontario, Canada. The app is our customers' and team's portal: people request a
> car, receive an offer from our staff, sign the rental agreement and pay by card (Stripe; the rental is a real-world
> service, so in-app purchase does not apply). Car owners in our program and our staff use the same app; the signed-in
> account decides which portal opens.
>
> Native features: push notifications for offers, payments, pickups, returns and messages (Profile, Phone alerts, then
> Send a test alert); the camera for the driver's licence, the selfie and the car's condition photos; Face ID unlock
> (Profile, App lock); links in our emails and texts open the app (universal links); an offline screen when there is no
> connection; the share sheet.
>
> Demo account (a renter with a confirmed booking): email `appreview@carmacars.ca`, password in the field below. To see
> account deletion: Profile, Delete my account (it opens a request our team completes within 30 days, as the screen
> says; withdraw it with Keep my account).

Before submitting: create that demo renter on the live site (a real mailbox or alias of rent@carmacars.ca, so its sign-in
emails arrive), give it a confirmed sample booking on a placeholder car (Admin can enter one), and put its password in
the stores' sign-in fields, never in this file. Export compliance (App Store): the app uses only standard HTTPS, so
**No** to non-exempt encryption (the build already says so in Info.plist).
