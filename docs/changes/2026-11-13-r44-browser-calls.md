# Calls in the browser, which cars are free, the hiring defaults, and Sales reading only their own leads (Release 44, part A: 2790 to 2792)

Migrations `2790_r44_browser_calls.sql`, `2791_r44_calls_hiring_guides.sql`, `2792_r44_fleet_availability.sql`.

## Why

Calls from the site never worked. The Twilio account, the caller ID and the secrets were never set, so the Call button
fell back to Quo, and for Sales (numbers masked) it was a dead end. The only way it had (release 35: ring the staff
member's own cell, then the customer) cannot work for the Sales staff abroad: their numbers are international, and
release 40 accepts Canadian and US mobiles only. The webhooks checked Twilio's signature only when the Auth Token was set.

## What changed

| Part | What changed |
| --- | --- |
| Calls in the browser | Staff place and take calls in the browser of the staff and Admin portals (Twilio Voice SDK 2.18.5, self-hosted under `/vendor`, loaded on staff pages only), with the CarmaCars number as caller ID. A bar at the bottom left shows the call (Calling, the timer, Mute, Keypad, Hang up) |
| Placing a call | The server keeps the call (`outbound_calls.via = 'browser'`) and gives the browser only the call's id and our token for it; the TwiML App's Voice URL (`/api/webhooks/twilio/client`) checks Twilio's signature, our token and that the browser is the staff member who started it, then dials the customer. Sales never receives a masked number |
| Incoming calls | A call to the business number (a Twilio number, Voice URL `/api/webhooks/twilio/incoming`) rings the browsers of the staff with a staff page open whose role rings (customer service and Sales by default), each shown the caller as they may see them (a name, or the number masked for Sales). Nobody online or nobody answered: a short message and the missed-call handling of every call, or a forward to the number an Admin sets. Never a staff member's own number |
| Settings | Program settings: Calls in the browser (on), Whose browser rings (cs, sales), Ring for (25 s), Nobody answered: forward to (empty), Nobody answered: the message, Ring my own mobile first (off; the release 35 way) |
| Twilio setup | The site finds or makes the TwiML App "CarmaCars browser calls" itself and points a Twilio business number with no Voice URL at the site. `TWILIO_AUTH_TOKEN` is required: every webhook is checked against Twilio's signature, fail closed, on the site's own https address (Cloudflare ends TLS, so `req.url` is never trusted). The caller ID is put in E.164 whatever form it was typed in. A value saved in the wrong secret is named |
| Content security policy | Staff and Admin pages only: `wss://*.twilio.com`, `https://eventgw.twilio.com` and `https://sdk.twilio.com` |
| Hiring | The AI interview decides by itself again (on; the release 43 rules hold). The welcome email and note give no start date (it read as "you work tomorrow"): training and claiming shifts only, then a hello in the team chat and the member tag "Name - Position" in each WhatsApp group, also a first-day To do. The email's steps showed one letter each (a wrong call of the steps block): fixed, with an Open the staff portal button |
| Which cars are free | Top of **Calendar** in the Admin and staff portals (Sales, customer service, fleet): a pickup and a return, every car Available or Not available with the reason (booked, on rent, payment due, placeholder, maintenance, cleaning, blocked, out of service, leaving the fleet) and the next free start for the same length; available first; class, seats and price a day filters. `va_read` / `admin_read` `fleet_availability` (app.fleet_availability) uses the booking's own rule (app.vehicle_is_available with the turnaround); no renter is named. **Offer these dates** opens Send an offer with the car and the dates (`?car=&from=&to=`) |
| Calendar | The legend says on rent, confirmed, request, offer or hold, maintenance (service, repair and cleaning blocks in blue stripes), not blocking, placeholder, block; short holds look like offers |
| Sales and leads | A person who works in Sales only reads and changes, from their own session, only their own leads (assigned, brought in, added, claimed now, or their sale outcome): two restrictive row policies. Through the door the numbers stay masked as before |

## Owner setup (names only)

GitHub repository secrets (and `secrets/deploy.sops.yaml` when SOPS is used): `TWILIO_ACCOUNT_SID`, `TWILIO_API_KEY`,
`TWILIO_API_SECRET`, `TWILIO_AUTH_TOKEN`; `TWILIO_CALLER_ID` when the business number differs from Site settings;
`TWILIO_TWIML_APP_SID` optional. In Twilio: the business number is a Twilio number (or a verified caller ID for outbound
only); incoming calls ring browsers only when calls to the business number reach a Twilio number.

## Guides

- `va/texts-and-calls`: calls in your browser, incoming calls, never your own number
- `va/start-here`: once you are hired, the team chat and the WhatsApp member tag
- `field/start-here`: the same for field staff
- `admin/texts-and-calls-the-quo-phone-line`: calls in the browser, the settings and the Twilio setup
- `admin/hiring`: the AI decides by itself by default, the welcome without a start date
- `va/shared-tools`: which cars are free, Offer these dates, the legend
- `admin/calendars`: the same, for Admins
