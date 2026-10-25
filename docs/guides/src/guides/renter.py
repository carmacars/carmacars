from lib import Guide, S, B, P, U


def build():
    g = Guide(
        key='renter', title='Renter Portal Guide', short='Renter',
        promise='Find a car, book it and manage your trip, step by step.',
        cover_shot=S('renter/03-offer-phone', 0, 595, 390, 1350),
        audience='renters', signin_url='carmacars.ca/sign-in', lands_on='Trips, your list of bookings')

    g.start_page(
        who='Anyone who rents a car from CarmaCars. You can send a request without an account. '
            'Your account keeps your trips, offers, agreements, receipts and documents in one place.',
        need=['A G or G2 licence (licences from outside Ontario are reviewed by a person)',
              'A credit card in your own name',
              'Your email address and a mobile number'],
        first_steps=[
            f'Go to {U("carmacars.ca/create-account")}. Enter your Full name, Email and a Password of 8 characters or more.',
            f'Tick the box to agree to the terms, then press {B("Create account")}.',
            f'Open the email "Confirm your CarmaCars account" and press its link within 24 hours. It confirms your email and opens Trips.',
            f'Next time, sign in at {U("carmacars.ca/sign-in")} with your email and password. Link expired? Sign in and press {B("Send a new confirmation link")}.',
        ],
        shot=S('public/10-create-account-phone', 0, 595, 390, 1275, pins=[(2, 372, 1253)]),
        note='Sent a request before you had an account? Once your email is confirmed, those requests are added to your '
             'account and Trips says "We found earlier requests made with your email".')

    # ---------------------------------------------------------------- 1
    g.chapter('Find a car and send a request',
              'Every booking starts as a request. A person checks the car and the price, then sends you an offer. '
              'Nothing is charged until you approve, sign and pay.',
              blurb='Search the fleet, pick dates and add-ons, and send a request in five short steps.')
    g.flow([('Request', 'You pick a car and dates'), ('Offer', 'We confirm the price'),
            ('Sign', 'The rental agreement'), ('Pay', 'Your card is authorized'),
            ('Verify', 'Licence, selfie, coverage'), ('Pick up', 'We hand over the keys')])

    g.task('Find a car', 'Start on carmacars.ca. You do not need to sign in to look around.')
    g.steps([
        f'Go to {U("carmacars.ca")} and press {B("Find a car")}.',
        'Add your pickup and return dates. The list then shows the cars that are free and what the whole trip costs.',
        'Narrow the list with Filters: type, seats, transmission and daily rate.',
        'Open a car to see its photos, rates, what is included and its own calendar. Its car code (like CC-7F3A) is under the price: quote it when you call or chat with us, and we know the car at once.',
    ], shot=S('public/02-cars-desktop', 0, 0, 1440, 880,
              pins=[(1, 1240, 35), (2, 160, 500), (3, 30, 724), (4, 490, 770)]))

    g.task('Choose your dates on the car page')
    g.steps([
        'Under Dates and price, tap your pickup date, then your return date. Hatched days are already booked.',
        'Choose the Pickup time and the Return time.',
        f'Want it brought to you? Tick {B("Deliver it to me")} or {B("Pick it up from me at the end")}. Open Add-ons to add a baby seat, flowers, a full tank and more.',
        f'Check Your estimate, then press {B("Request to book")}. The add-ons you chose come with you.',
    ], shot=S('public/03-car-page-desktop', 290, 1350, 1410, 2110,
              pins=[(1, 563, 1652), (2, 435, 1868), (3, 300, 1929), (4, 1388, 1730)]))
    g.warn('A request does not hold the car. The car is booked only once you approve the offer, sign and pay.')

    g.task('Send your request', 'The request has five short steps. Your answers are saved as you go, so you can come back.')
    g.steps([
        'Step 1, Dates and delivery: check the car and tap your dates in the calendar.',
        'Set the Pickup time and Return time. Any time, day or night, with at least 2 hours of notice.',
        'Your request, on the right, shows the estimated total as you go.',
    ], shot=S('public/04-book-1-trip-desktop', 0, 280, 1440, 1210,
              pins=[(1, 133, 880), (2, 220, 1120), (3, 1312, 756)]))
    g.steps([
        f'Choose where you get the car: {B("At our location")}, {B("Deliver it to an address")} or {B("At the airport")}. Then choose where you return it.',
        f'Press {B("Continue to driver details")}.',
    ], shot=S('public/04-book-1-trip-desktop', 0, 1240, 760, 2110, pins=[(4, 40, 1415), (5, 470, 2047)]), fig_w=3.4)
    g.steps([
        'Step 2, The driver: fill in your first and last name, email, mobile number and date of birth.',
        'Someone else will drive too? Add them under Additional drivers. Each needs a G2 or G licence and signs the agreement.',
        f'Press {B("Continue to licence")}.',
    ], shot=S('public/05-book-2-driver-desktop', 0, 330, 980, 1290,
              pins=[(6, 300, 476), (7, 300, 927), (8, 545, 1166)]), fig_w=3.9)
    g.steps([
        'Step 3: choose your Licence class, for example Ontario G2.',
        'Choose how the car is covered: Option 1 (OPCF 27 on your own auto policy), Option 2 (rental coverage on your credit card) or Option 3 (the CarmaCars Protection Plan). You can change this any time before pickup.',
        'Choose the Booking type: Standard, or Non-refundable for 10% off with no refund.',
        'Add anything we should know in the notes, for example a flight number.',
        f'Press {B("Continue to add-ons")}. Step 4, Add-ons: tick what you want (see Add-ons below), then press {B("Review request")}.',
    ], shot=S('public/06-book-3-licence-desktop', 0, 380, 760, 1760,
              pins=[(9, 470, 470), (10, 700, 776), (11, 700, 1040), (12, 700, 1279), (13, 545, 1716)]), fig_w=3.0)
    g.steps([
        'Step 5, Check it and send: read every line. Use Edit beside a line to change it.',
        'Tick the box to confirm you are 18 or older and agree to the Terms of use and Privacy policy.',
        f'Press {B("Send request")}. Nothing is charged and no card is needed.',
    ], shot=S('public/07-book-4-review-desktop', 0, 1480, 760, 1900, pins=[(14, 700, 1530), (15, 30, 1700), (16, 560, 1846)]), fig_w=3.4)
    g.steps([
        'The confirmation shows your request number, for example CC-10021. Keep it for any question.',
        'A person checks the calendar, your dates and your place, usually within 2 hours, day or night. Your offer arrives by email and in Trips.',
    ], shot=S('public/08-book-5-sent-phone', 0, 595, 390, 1290, pins=[(17, 128, 628)]))

    g.task('Upload your licence', 'Right after you send your request: the front and back of your licence and a selfie holding it.')
    g.steps([
        f'On the Request sent page, press {B("Upload your licence")} (or open your booking and press {B("Your licence")}).',
        'Take each photo with your phone, or choose it. Add the licence number and expiry date if we ask: it must be valid after your return.',
        'Rented with us before? A licence on file that is still valid is used again; nothing to upload.',
    ])
    g.tip('You need your licence on file to accept the offer.')

    g.task('Add-ons', 'Extras for your trip, such as a baby seat, a child or booster seat, flowers waiting in the car, a chauffeur, an umbrella, a phone charger or a full tank of gas.')
    g.steps([
        'On the car page (under Add-ons) or in step 4 of the request, tick an add-on or use + and − for seats. The estimate shows the price at once.',
        'Each add-on shows its price: a trip, a day (with the most for a trip) or an hour. HST is added.',
        'Some need notice, for example flowers need 24 hours. Seats and other items show how many are left for your dates.',
        'A chauffeur is confirmed by our team in your offer.',
    ])
    g.para('With a full tank of gas (prepaid) you can return the car at any fuel level, with no fuel charge.')

    g.task('Ask in the chat', 'The chat button sits in the corner of every page.')
    g.steps([
        'Press it and write your question: a car, your dates, the price, how booking works. The CarmaCars assistant answers right away with prices from our booking system.',
        f'Want a person? Press {B("Talk to a person")}. When our team is away, leave your name and email or phone with {B("Send my details")} and tick "Email me a copy of this chat".',
        f'Press {B("End chat")} when you are done. If you gave your email, a copy of the chat arrives by email.',
    ])
    g.para('A price in the chat is for the dates you asked. Nothing is booked until you approve an offer, sign and pay.')

    g.task('Carry on later')
    g.bullets([
        'Your name, email and mobile number are saved as you type them, so nothing is lost if you stop. We open an account for you with that email.',
        'Every form that saves as you type says so under it: "Saved as you type so you can pick up where you left off.", with a link to the privacy policy.',
        f'On the same phone or computer, open {U("carmacars.ca/account")} (or the request page again) to carry on, no password needed.',
        'We send you one email, "Continue your request". One tap signs you in, confirms your email and opens your request on any device. You need it before you can accept an offer, sign or pay.',
        'Already have an account? The form says "You have an account: we sent you a sign-in link".',
    ])

    # ---------------------------------------------------------------- 2
    g.chapter('Your offer',
              'Our offer is the confirmed price for your car and dates, with every fee and HST. '
              'It stays open for 24 hours. You approve it, ask for a change or decline it.',
              blurb='Read the confirmed price, then approve, ask for a change or decline.')
    g.task('Open your offer')
    g.steps([
        f'We email you when the offer is ready. Sign in at {U("carmacars.ca/sign-in")} and open {B("Trips")}.',
        f'Your next trip is at the top, with a photo of the car and its next step. Press {B("Review offer")}.',
    ], shot=S('renter/02-trips-offer-desktop', 0, 0, 1440, 760, pins=[(1, 65, 205), (2, 165, 532)]))
    g.task('Approve, ask for a change, or decline')
    g.steps([
        'Check the price, the dates, the place and any message from our team. The black bar shows how long the offer stays open.',
        f'All good? Press {B("Approve and continue")} to sign and pay. No licence on file yet? The button says {B("Upload your licence to accept")}: upload it, then come back.',
        f'Want something different? Press {B("Ask for a change")}, write what you need, then {B("Send request")}.',
        f'Not going ahead? Press {B("Decline offer")}, then {B("Decline this offer")}.',
    ], shot=S('renter/03-offer-desktop', 0, 280, 1440, 1110,
              pins=[(1, 1240, 316), (2, 1020, 667), (3, 1020, 732), (4, 1110, 790)]))
    g.warn('This offer does not hold the car. If someone else approves, signs and pays for the same car and dates first, '
           'we tell you and offer you another car or other dates.')

    # ---------------------------------------------------------------- 3
    g.chapter('Sign and pay',
              'After you approve, you sign the rental agreement on screen and pay. '
              'It takes a few minutes on a phone or a computer; the signing itself is three taps.',
              blurb='Sign the rental agreement on screen and pay with your card.')
    g.task('Sign the rental agreement')
    g.steps([
        'Fill in your home address and licence details. You do this once; we keep them for next time.',
        f'Press {B("Save details")}. The agreement then shows your details.',
    ], shot=S('renter/04-sign-details-desktop', 0, 560, 1440, 1540, pins=[(1, 640, 760), (2, 235, 1502)]))
    g.steps([
        f'Check the key values at the top: the car, the dates, the deposit and the deductible. Open {B("Read the full rental agreement")} to read it word for word, or press {B("Download PDF")} to keep a copy. Below it is the Blind Spot Car Rental agreement, filled in with the same booking: we rent under Blind Spot\'s insurance, so it is part of your rental too. Press its {B("Download PDF")} to read it.',
        f'Under Sign, tap {B("All four")}: it ticks the four statements, which stay on screen to read.',
        f'Your full legal name is your signature. Prefer to sign with your finger or the mouse? Press {B("Draw instead")}.',
        f'Press {B("Sign and continue to payment")}. Your one signature signs both agreements; the signed copies are in Documents and in the email that confirms your booking.',
    ], shot=S('renter/06-sign-ready-desktop', 0, 700, 1440, 1840,
              pins=[(3, 850, 736), (4, 1000, 848), (5, 1300, 1580), (6, 1395, 1684)]))

    g.task('Signing with our staff', 'At pickup or at our desk, you can sign on a CarmaCars phone or tablet.')
    g.steps([
        'Our staff member checks your name and your original licence, then hands you the device.',
        f'Read the agreements, tick the statements and sign with your name or your finger. Then hand the device back.',
        'It is the same signature as signing online. Prefer your own phone? Ask for the signing link by email or text.',
    ])

    g.task('Pay to confirm')
    g.steps([
        'Check What you pay now. The refundable deposit is taken at pickup, not today.',
        'Enter the Name on the card and the card details. Use a credit card in your own name.',
        f'Press {B("Pay $...")} (the button shows the amount).',
    ], shot=S('renter/07-pay-desktop', 0, 450, 1440, 1460, pins=[(7, 1015, 615), (8, 930, 557), (9, 930, 1421)]))
    g.tip('Your card is authorized now and charged once the booking is confirmed. It becomes your Card on File for the '
          'deposit at pickup and any later charges you agreed to when you signed.')
    g.warn('See "This car was just taken"? Someone confirmed the same car first. The authorization on your card is '
           'released, and we offer you another car or other dates.')

    g.task('A rental we booked for you', 'Booked by phone, in person or through a partner? We add the rental and you sign it online.')
    g.steps([
        'You get an email: "Read and sign your rental agreement; your card is charged when you sign."',
        'Open it. Check the car, the dates and the price, and read the agreement.',
        f'Press {B("Accept and sign")}. If we have your card on file, it is charged at that moment, not before, and the agreement is countersigned by CarmaCars as soon as you sign.',
    ])

    # ---------------------------------------------------------------- 4
    g.chapter('Before pickup',
              'Your booking is confirmed. A few things are left: your licence photos, a selfie and proof of '
              'coverage, a signature from each additional driver, and the deposit.',
              blurb='Upload your licence and coverage, send driver links, and know what to bring.')
    g.task('Your booking page', 'Every booking opens with a large photo of your car, its name, the status and a clock: "Pickup in 2 days 4 h", or "Return by Sun 7 PM" while you have the car.')
    g.steps([
        f'Open {B("Trips")}, then your booking. The status is on the photo, for example Confirmed, with your booking number.',
        'Under the photo: when and where you pick up and return the car (tap a place to open it in Maps), the kilometres included, the fuel rule and the deposit.',
        f'Next step tells you the one thing still needed, with its button, for example {B("Upload documents")}. When nothing is needed it says you are all set, with {B("Add to calendar")}.',
        f'Manage your trip holds {B("Licence and coverage")}, {B("Extend")}, {B("Ask to change dates")}, {B("Message us")}, {B("Call us")}, {B("Add a driver")}, {B("Documents")} and {B("Cancel booking")}.',
    ], shot=S('renter/08-booking-confirmed-desktop', 0, 280, 1440, 1240,
              pins=[(1, 140, 760), (2, 135, 990), (3, 1100, 1010)]))
    g.para(f'Money, on the right (below on a phone), shows what you paid and what is owing, part by part, with a {B("Pay")} button when something is open and your receipts. {B("Price details")} opens every line of the price. Progress shows how many steps are done; {B("Every step")} lists them, from Request sent to Statement.')

    g.task('Upload your licence, selfie and coverage', 'Do this at least 24 hours before pickup. It takes a few minutes with your phone.')
    g.steps([
        f'On your booking, press {B("Upload documents")} (or {B("Licence and coverage")}).',
        f'Licence, front: lay the licence on a dark surface with all four corners visible. Press {B("Take photo")}.',
        'Licence, back: do the same for the back.',
        f'Selfie with your licence: hold the licence beside your face, then press {B("Take selfie")}.',
        f'Coverage for damage to the car: add what your option asks for, then press {B("Upload proof")}.',
    ], shot=S('renter/09-verify-desktop', 0, 280, 1440, 1440,
              pins=[(2, 267, 1012), (3, 720, 991), (4, 1170, 991), (5, 720, 1382)]), fig_w=6.2)
    g.table([
        ['Option 1, OPCF 27 on your own policy', 'Your insurer, the policy number and its expiry (after your return date), and the policy or endorsement that shows OPCF 27, as a PDF or photos (up to 6 pages).'],
        ['Option 2, your credit card\'s rental coverage', 'Pay with that card: it must be a credit card (debit and prepaid cards are refused) in your name. Tick that it covers this kind of car for this many days. The card\'s benefits document is optional.'],
        ['Option 3, the CarmaCars Protection Plan', 'Ask for it on your booking; we confirm it once it is active.'],
    ], head=['Your option', 'What we need'])
    g.tip(f'Which cards include rental car coverage? {U("carmacars.ca/credit-card-rental-coverage")} lists them, with each card\'s car value limit (MSRP), its longest rental and a link to its guide. '
          'Most cards stop at a car priced $65,000 or $85,000, and some of our cars are priced higher. Only your card\'s issuer decides a claim: call the number on the back of your card before you rent.', label='Good to know')
    g.tip('A person checks your proof and approves it, or tells you what to fix. The car is handed over only once it is approved. Changing your option replaces the earlier proof. '
          'We remind you 48 and 24 hours before pickup while it is missing. We delete licence and face photos 90 days after your rental ends.')

    g.task('Additional drivers', 'Each additional driver signs the agreement with their own link.')
    g.steps([
        'When the agreement is ready, each driver with an email gets their own signing link.',
        f'On your booking, press {B("Copy their signing link")} to send it yourself, or {B("Send a new link")}.',
        'Each driver adds their own licence photos and selfie, like you did.',
    ])
    g.warn('Signing links expire after 72 hours. A new link ends the older one, so always send the newest.')

    g.task('Add something to your trip', 'Until 24 hours before pickup (or the notice an add-on needs), add add-ons from your booking.')
    g.steps([
        f'On your booking, under Add-ons, press {B("Add something to your trip")}.',
        'Tick the add-on you want. Its price shows below.',
        f'Press {B("Add and pay")}. It is charged at once on the card you paid with, and shows on your booking and receipt.',
        f'A chauffeur needs our confirmation: press {B("Ask for it")}. We confirm it and charge your card then.',
    ])
    g.para(f'No card on file for this booking? The add-on is added and waits for payment: press {B("Pay for your add-ons")} under Add-ons, enter a card and press {B("Pay")}. It is charged at once; that card is not kept.')
    g.tip('If you cancel, add-ons are refunded like the rest of your booking. Flowers and a chauffeur are not refunded once their notice before pickup has started.')

    g.task('What to bring to pickup')
    g.bullets([
        'Your original licence. A photo is not enough.',
        'The card you paid with. The deposit is taken on it about an hour before pickup.',
        'A few minutes to walk around the car with us. We photograph it together.',
    ])

    # ---------------------------------------------------------------- 5
    g.chapter('During your trip',
              'Plans change. You can ask for more days, ask to change dates, answer a change we suggest, '
              'or cancel, all from your booking.',
              blurb='Extend, change dates, answer a change we suggest, or cancel.')
    g.task('Extend your rental')
    g.steps([
        f'On your booking, press {B("Extend")}.',
        f'Choose the new return date and time, then press {B("See the price")}.',
        f'Press {B("Request extension")}. Once we approve it, press {B("Pay for the extension")} before your current return time.',
    ], shot=S('renter/11-extend-desktop', 0, 280, 960, 760, pins=[(2, 330, 555), (3, 145, 634)]), fig_w=3.9)
    g.warn('Ask before your current return time. One rental can be at most 30 days.')

    g.task('Ask to change dates')
    g.steps([
        f'On your booking, press {B("Ask to change dates")}.',
        f'Set the new pickup and return, then press {B("See the difference")} to see what you would pay or get back.',
        f'Press {B("Ask to change dates")} to send it. Nothing changes until you agree to our answer.',
    ], shot=S('renter/12-change-desktop', 0, 280, 960, 760, pins=[(2, 145, 715)]), fig_w=3.9)

    g.task('A change we suggest', 'Sometimes we need to change your booking, for example another car of the same class. You decide.')
    g.steps([
        f'You get an email, and your booking says "We suggest a change to your booking". Press {B("Review and answer")}.',
        'Read what changes (before and after), the reason, the money and the time left to answer.',
        f'To agree, press {B("Accept and sign the amendment")}, sign, then press {B("Accept and sign")}.',
        f'Anything more to pay is charged to your Card on File. If the card is declined, press {B("Pay and apply the change")}.',
        f'To say no, press {B("Decline this change")}. Your booking stays as it was.',
    ])
    g.tip('You have 48 hours to answer, and we send one reminder. CarmaCars signs the amendment at the moment you sign it, and the signed copy is saved under Documents. '
          'If the change costs less, the refund goes back to your card within 10 business days after the amendment is signed.')

    g.task('Cancel a booking')
    g.steps([
        f'On your booking, press {B("Cancel booking")}.',
        'Read What you get back. It shows the rule that applies and your refund.',
        f'Type the booking number to confirm (for example CC-10021), then press {B("Cancel booking")}.',
    ], shot=S('renter/13-cancel-desktop', 0, 280, 1440, 900, pins=[(2, 520, 673), (3, 1380, 520)]))
    g.table([
        ['Within 24 hours of booking, and 48 hours or more before pickup', '95% back'],
        ['48 hours or more before pickup', '75% back'],
        ['24 to 48 hours before pickup', '50% back'],
        ['Less than 24 hours before pickup', 'No refund'],
    ], head=['Standard booking: when you cancel', 'Refund of what you paid'])
    g.para('A Non-refundable booking gets no refund. The deposit is taken at pickup, so none is held when you cancel before it.')

    g.task('Messages, tolls and tickets')
    g.bullets([
        'On a rental of 2 days or more we check in after the first day: "How is the car?" If anything is off, reply to the email or text, or call us.',
        'Write to us about a booking at the bottom of its page: type in Your message and press Send.',
        'Tolls and tickets are yours to pay, including Highway 407 ETR. If one reaches us, we pay it and charge the amount '
        'plus our fee to your Card on File, and email you a copy of the notice.',
        f'Running late? Ask to extend before your return time, or call us at 289-312-5991.',
        f'Something wrong with the car? While you have it, press {B("Report a problem")} on your booking: it calls roadside help, or opens a message to us.',
        f'Someone else will drive too? Press {B("Add a driver")}: write their name in the message and we add them; they sign with their own link.',
    ])

    # ---------------------------------------------------------------- 6
    g.chapter('After your trip',
              'We check the car with you at the return. Your deposit balance comes back, and your receipts and '
              'agreement stay in your portal.',
              blurb='The return, your deposit, reviews, documents and your profile.')
    g.task('The return and your deposit')
    g.bullets([
        'At the return we check the odometer, fuel or charge, keys and cleanliness, take photos and compare with pickup. You sign on our screen.',
        f'The photo report of the pickup and the return is in your email, in Documents and on your booking ({B("Photo report")}): the times, the kilometres, the fuel, every photo and any damage. A late return, kilometres over the allowance or less fuel than at pickup are charged from these readings.',
        'We release the deposit balance after you return the car. If a toll, ticket or claim is still open, we may hold back what we expect it to cost for a while.',
        'Your statement appears under Documents.',
    ])

    g.task('Review your trip', 'After the return we send you a link by email or text. It takes about a minute, and we help you write it.')
    g.steps([
        'Open the link. Tap what you liked: the car, the pickup or delivery, communication, the price, cleanliness, how easy booking was, or the name of the person who helped you.',
        'If you like, tap the stars for how it felt, and write one sentence in your own words.',
        'Your review appears, made only from what you picked and wrote and the facts of your booking. Change anything you like.',
        f'Press {B("Post on Google")}: it copies your review and opens Google. Choose your stars and paste it. {B("Copy")} only copies it.',
    ])
    g.para('Already left a review? Press "I already left a review" and we stop asking. Something wasn\'t right? The page offers to tell us directly. '
           'We never offer anything for a review, and every renter gets the same link.')
    g.task('Review your rental on our site')
    g.steps([
        f'Open the trip under Past trips, then press {B("Review your rental")}. Liked the car? {B("Book again")} opens it for new dates.',
        'Tap the stars. Add a title and a few words if you like. Both are optional.',
        f'Tick {B("Show my review on the site with my first name")} only if you agree to it being shown.',
        f'Press {B("Send my review")}.',
    ], shot=S('renter/14-review-desktop', 0, 280, 1440, 880, pins=[(2, 360, 434), (3, 50, 776), (4, 260, 829)]))

    g.task('Documents, notifications and profile')
    g.steps([
        f'{B("Documents")}: your agreements, receipts, statements and uploads. Press {B("View")} or {B("Download")}.',
        f'{B("Notifications")}: notices from us. Use {B("Mark as read")} or {B("Mark all as read")}, and choose which optional emails you get.',
        f'{B("Profile")}: your contact details ({B("Save")}), drivers, your Card on File and your marketing choice.',
    ], shot=S('renter/15-documents-desktop', 0, 0, 1440, 560, pins=[(1, 1322, 200)]))
    g.tip('Your legal name is locked once you are verified. To change it or your email, call or message us.')

    g.task('Sign in with your phone number', 'No password needed: we text you a 6-digit code from the CarmaCars number.')
    g.steps([
        f'On {U("carmacars.ca/sign-in")}, press {B("Use my phone number instead")}.',
        f'Enter your mobile number and press {B("Text me a code")}. Codes go to Canadian mobile numbers.',
        f'Type the 6-digit code from the text (on most phones it fills itself in), or press {B("Sign in")}. The code works for 5 minutes; {B("Send a new code")} after a minute if it did not arrive.',
        f'To sign in by phone every time, open {B("Profile")}, press {B("Add and verify my phone number")}, enter the code we text you, then choose {B("My phone number (a code by text)")} under Sign in with. The sign-in page then opens on your phone number.',
    ])
    g.tip('New here? On Create account, press Sign up with my phone number instead: your name, your mobile number and the code. '
          'An account made by phone has no email yet: you can send requests, accept offers and sign, and the pay page asks for your email '
          'before your first payment, for the receipts. A booking request you sent earlier with the same mobile number is added to your account once the code is checked.')

    g.task('Texts or email: how we reach you', 'Choose Email, Text or Both. Texts are short, come from the CarmaCars number and link to the page.')
    g.steps([
        f'Open {B("Profile")}. Under {B("Messages")}, choose {B("Email")}, {B("Text")} or {B("Both")}. It is saved at once.',
        'Texts go to the phone you verified with a code (Sign-in, above). Until you verify one, we email you.',
        'Signed agreements, statements and receipts are always emailed when we have your email. On Text you also get a text with a link to view or download them.',
        'No texts from 9 pm to 8 am, except urgent ones such as a late return. Reply STOP to any text to stop texts (we confirm with one text); text START to turn them back on.',
    ])
    g.tip('You can also choose in the booking request (How should we reach you?) and when you sign up with your phone number, where Text is chosen for you.')

    g.reference(
        nav_rows=[('Trips', 'Your next trip with its photo and next step, then upcoming and past trips'),
                  ('Documents', 'Agreements, receipts, statements, uploads'),
                  ('Notifications', 'Notices and your email choices'),
                  ('Profile', 'Contact details, drivers, Card on File')],
        top_tasks=[('Request a car', f'{B("Find a car")}, the car, then {B("Request to book")}'),
                   ('Approve an offer', f'{P("Trips", "Review offer", "Approve and continue")}'),
                   ('Sign and pay', f'{B("All four")}, {B("Sign and continue to payment")}, then {B("Pay $...")}'),
                   ('Upload documents', f'{P("Your booking", "Licence and coverage")}'),
                   ('Extend or change dates', f'{B("Extend")} or {B("Ask to change dates")}'),
                   ('Answer a change we suggest', f'{B("Review and answer")}'),
                   ('Cancel', f'{P("Your booking", "Cancel booking")}'),
                   ('Review your trip', f'{B("Review your rental")}')],
        extra_problems=[('"This car was just taken"', 'Someone confirmed first. Your card is released; pick from the car or dates we offer.'),
                        ('No confirmation email', f'Check spam, then use {B("Send the confirmation link again")} on the sign-in form.')])
    return g
