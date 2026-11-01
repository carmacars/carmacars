# Facebook Marketplace playbook

The owner's decision (October 24, 2026): Meta's built-in Marketplace auto-replies answer the first message, and Claude
posts the listings and answers the Marketplace inbox through the owner's own Chrome (Claude in Chrome). Listings go up
from the owner's personal Facebook profile, because business Pages cannot post vehicles to Marketplace.

Everything Claude needs is on one Admin page: **Admin > Marketing > Marketplace** (`https://carmacars.ca/admin/marketing/marketplace`).
That page has:

- **Today**: what to post, renew, update or take down today. It is a light rotation of `posts_per_day` (4) new posts and
  renewals a day. Price updates and take-downs are always due and do not count toward the 4.
- **Kit**: one car's listing, field by field in the order Facebook asks for them, with the Marketplace-style
  description, the tracked link, the 10 best photos in order (**Download the photos (ZIP)**), and the inbox replies
  filled in for that car.
- **Log an inbox session**: the chat count and every phone number collected. Each new number becomes a lead with a
  call-back task for customer service within 15 minutes.
- **Log**: what was done, and by whom.

Every kit is built when the page opens, so its prices are always today's. When a car's rates change by 3% or more, or
its deposit, kilometres, delivery fee or availability change, its live listing is marked **Update the price** and an
`ad_update` task opens (migration 0167).

## 0. One-time setup (the owner)

1. In Chrome, sign in to **facebook.com** with the personal profile that posts the cars, and to **carmacars.ca** as Admin
   (rent@carmacars.ca). Keep both signed in.
2. In the Claude app, connect the folder **Downloads** (or a folder such as `Downloads/CarmaCars Marketplace`) so Claude
   can unzip the photo ZIPs and attach the photos. Chrome must save downloads into that folder without asking
   (chrome://settings/downloads: turn off "Ask where to save each file").
3. Turn on Meta's auto-reply in each new listing (section 5). Claude does this while posting, but check the first one.
4. Allow the Claude in Chrome extension on `facebook.com` and `carmacars.ca`.

## 1. A session

The owner opens the laptop with Chrome running **twice a day**: about **10:30 am** (post and renew, then the inbox) and
about **7:30 pm** (the evening inbox, when most messages arrive). Each session takes about 20 to 40 minutes. To start,
tell Claude: "Run the Marketplace session."

Claude then:

1. Calls `tabs_context_mcp` and opens a **new tab**. It never uses or closes the owner's own tabs.
2. Opens `https://carmacars.ca/admin/marketing/marketplace` and reads **Today** (`get_page_text`).
3. Does the due items in this order: **Update the price**, **Take down**, **Post**, **Renew** (sections 2 and 3).
   It never goes over the day's allowance. **Left today** shows what is left.
4. Answers the inbox (section 4) and logs the session.
5. Leaves the Admin page open on **Log**, so the owner can see what was done.

**Stop and hand over to the owner** on any of these: a Facebook security check, a CAPTCHA, a "confirm it's you"
screen, a notice that a listing was removed or the account is restricted, a request for ID or payment details, an
angry or legal message, or a question the templates do not answer. Claude never completes a CAPTCHA, never types a
password, and never sends money or card details.

## 2. Posting a car

For each **Post** item on Today:

1. On the Admin page, press **Kit** for the car. Read the fields, the description and any **Do not post yet** line.
   If that line is shown, skip the car.
2. Press **Download the photos (ZIP)**. The file `carmacars-<car code>-marketplace.zip` lands in Downloads. Unzip it
   into a folder of the same name (`device_bash`: `unzip -o <zip> -d <folder>`). The photos are named `01.jpg` to `10.jpg`.
3. Open `https://www.facebook.com/marketplace/create/vehicle` in the same tab.
4. **Photos**: find the hidden file input (`find` "Add photos" file input) and use `file_upload` with the 10 paths in
   order, 01 first. Keep each call under 10 MB; if the photos are bigger, upload 01 to 05, then 06 to 10.
5. Fill the fields from the kit, in the order they appear:

   | Facebook field | From the kit |
   | --- | --- |
   | Vehicle type | Car/Truck |
   | Location | Location (type it, then choose the matching town in the list) |
   | Year | Year |
   | Make | Make (choose from the list) |
   | Model | Model (choose from the list; if the list has no trim, choose the model alone) |
   | Mileage | Mileage (km) |
   | Price | Price (whole dollars: the daily rate; the description says it is per day) |
   | Body style | Body style |
   | Exterior colour | Exterior colour |
   | Interior colour | Look at photo 04 or 05 (the seats) and pick the nearest colour |
   | Clean title | Leave unticked |
   | Vehicle condition | Vehicle condition |
   | Fuel type | Fuel type |
   | Transmission | Transmission |
   | Description | Copy the kit's **Description** whole |

6. If the form shows **Auto replies** (also called Meta AI replies), turn it on and replace the drafted reply with the
   auto-reply text in section 5.
7. Press **Next**. Do not add the listing to groups and do not boost it. Press **Publish**.
8. Open the new listing, copy its address (`https://www.facebook.com/marketplace/item/<number>/`), go back to the Admin
   page and press **Posted** on that car. Paste the address and keep today's date.

If Facebook holds the listing back or rejects it for the link, edit the listing and paste **The description without
the link** from the kit. Then log it as **Updated**. If it is rejected again, stop and tell the owner.

Never post a car whose kit has only sample photos, and never post the same car twice. Repost a car (delete the old
listing, post again) only when renewing is not offered. Then log it as **Posted** with the new address, which ends
the old ad in Admin.

## 3. Renewing, updating, taking down

- **Renew**: open the listing (Today has **Open listing**), or go to Marketplace > Selling > Your listings. Choose the car,
  then **Renew listing** (Facebook offers it about a week after posting). Back in Admin, press **Renewed**. If Facebook
  does not offer Renew yet, leave it for tomorrow and do not log it.
- **Update the price**: open the listing, then **Edit**. Set **Price** to the kit's price and replace the description with
  the kit's description. **Update**. In Admin press **Updated**. This also closes the `ad_update` task.
- **Take down**: the car is not taking requests. Open the listing, then **Mark as sold** (or **Delete listing** if the car
  is leaving for good). In Admin press **Taken down** and write why.

## 4. The inbox

1. Open `https://www.facebook.com/marketplace/inbox/` (the **Selling** tab). If it does not load, use
   `https://www.messenger.com/marketplace`.
2. Work from the oldest unanswered conversation to the newest. Each conversation shows the listing it is about. Match it
   to the car on the Admin page by name. The kit's **Inbox replies for this car** has every reply already filled in.
3. Choose the reply that fits the question (the table below), paste it, and send it. Send one message per reply, never
   several in a row.
4. When someone sends a phone number, send **After they send a number**, then write the line `name, number, car code`
   down for the log.
5. When the inbox is done, go back to Admin, open **Log an inbox session**, and enter the number of conversations
   answered, the replies sent, and the numbers collected (one per line: `Sam, 416 555 0142, CC-7F3A`). **Log the session**.

Rules for replies:

- Use the templates only. The owner approved these words for Claude to send. Anything else, such as a discount, a
  different price, a promise of a car on dates, a cash deal or a question about an accident, gets the **Send your number**
  reply and goes to the owner or customer service.
- Never ask for or accept a licence photo, card number or payment in Messenger. Those go only through carmacars.ca.
- Never share anyone's personal details, the owner's address, or the names of other renters.
- Do not reply to spam, scams ("I'll send a courier", "pay by cheque", links to other sites) or abuse. Leave them unanswered
  and mention them to the owner.
- Reply to one person at most twice without an answer. After that, stop.

### Reply templates

The Admin page fills these in for each car (price, deposit, delivery, age and the tracked link with
`utm_content=reply`). The text is the same as below. `{link}` is the car's tracked link.

| When | Reply |
| --- | --- |
| "Is this still available?" (first message) | Hi! Yes, the {car} is available to rent. Pick your dates and see the full price here: {link} Send your phone number and we will call you in a few minutes. |
| Price: how much, best price, weekly, monthly | The {car} is {daily} a day, {weekend} a day on weekends, {weekly} a week, {monthly} for 30 days, plus HST, with {km} km a day included. Longer rentals cost less a day. Your exact total for your dates shows here before you send anything: {link} Send your phone number and we will call you in a few minutes. |
| Availability: is it free on my dates, today, this weekend | The live calendar for the {car} is here, and you can request your dates in 2 minutes (nothing is charged until we confirm): {link} Or send your number and your dates, and we will call you to book it. |
| Requirements: age, G2, insurance, credit card | To rent: age {min age} or older, a G2 or G licence, and one coverage option: OPCF 27 on your own auto policy, a credit card that includes rental coverage, or our Protection Plan. A credit card in your name for the deposit. Request here and upload your licence: {link} Send your phone number and we will call you in a few minutes. |
| Deposit: how much, cash | The refundable deposit for the {car} is {deposit}, held on pickup day and returned after the trip once tolls and tickets are clear. Full details for your dates: {link} Send your phone number and we will call you in a few minutes. |
| Delivery: can you deliver, where is it | Yes, we deliver across Ontario from {delivery} each way, or you can pick it up from us. Put your address in the request and the delivery price is in your total: {link} Send your phone number and we will call you in a few minutes. |
| Send your number: anything else, a long chat, a haggler, someone ready to book | Easiest by phone. Send your number and one of our team will call you in a few minutes, or call or text us at {phone}. You can also book directly here: {link} |
| Right after they send a number | Thank you! Someone from CarmaCars will call you shortly. To save time, you can start the request here: {link} |

## 5. Meta auto-replies (the owner)

Meta's Marketplace auto-reply answers buyers who ask whether an item is available. Meta AI drafts the reply from the
listing's description, availability, location and price, and the seller can turn it on, preview it and edit it while
creating the listing. Meta has not said whether every account and every listing type has it. If the vehicle form does
not show it, Claude's inbox sessions cover the first message instead.

To set it up, on each new listing (Claude does this while posting; check the first one yourself):

1. On facebook.com/marketplace/create/vehicle, fill in the listing and scroll to **Auto replies** (or **Meta AI replies**)
   near the description, before **Next**.
2. Turn it **on** and open the drafted reply to edit it.
3. Replace all of the draft with this text, putting the car's tracked link from the kit in place of the link:

   > Hi! Yes, it's available to rent (not for sale). See the price for your dates and request it in 2 minutes: {link}
   > Or send your phone number and our team will call you shortly.

4. Publish. For an older listing, open it, choose **Edit**, and set the same reply if the option is shown.

The auto-reply only answers the first "Is this available?" message. Every other message waits for a Claude session or a person.

## 6. Tracking where the leads come from

- **Every link** carries `utm_source=fb_marketplace`, `utm_medium=marketplace` and `utm_campaign=<car code>`. Links sent in
  replies also carry `utm_content=reply`. A booking request from such a visit counts under Facebook Marketplace in
  **Admin > Marketing > Bookings by channel**.
- **"How did you hear about us?"** is an optional question on the booking request (step 2, Driver). It counts after staff's
  own source and a tracked visit. So a Marketplace renter who typed carmacars.ca by hand is still counted for Marketplace.
- **Phone numbers** logged from the inbox are leads with source `fb_marketplace`. Each one gets a call-back task, and on a
  booking staff set **Came from: Facebook Marketplace**.
- The Marketplace page's tiles show this week's chats and numbers, and the last 30 days' Marketplace requests and
  call-back leads.

## 7. Limits

- Keep to 3 to 5 new posts or renewals a day (the setting is under **Rotation settings**). Bursts of near-identical
  listings are what Facebook flags.
- Meta's commerce rules are written for selling things. Facebook can remove rental listings in the Vehicles category, or
  restrict an account that posts many of them. The description always says "for rent, not for sale". If a listing is
  removed, do not appeal or repost it: tell the owner.
- Facebook's pages change. If a field or button described here is not where this playbook says it is, look for it by
  its label. If it is not there at all, stop and tell the owner instead of guessing.
