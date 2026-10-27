from lib import Guide, S, B, P, U


def build():
    g = Guide(
        key='va', title='VA Portal Guide', short='VA',
        promise='Your queue, your tools and your targets, for every function.',
        cover_shot=S('va-cs/01-queue-phone', 0, 595, 390, 1350),
        audience='staff', signin_url='carmacars.ca/sign-in?next=/va', lands_on='To do, the tasks of your function')

    g.start_page(
        who='CarmaCars assistants (VAs) in Customer service, Finance, Fleet and Sales. Read chapter 1, then the chapter '
            'for your function. If you cover more than one, read each of them.',
        need=['The invitation email from CarmaCars (the link works for 24 hours)',
              'A computer for your shift. The portal also works on a phone',
              'An authenticator app on your phone, if your Admin turns on two-step sign-in'],
        first_steps=[
            f'Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press {B("Save the new password")}.',
            f'You land in your portal, on {B("To do")}, working as your main function.',
            f'At the top of the page, fill in your Home address and Postal code and press {B("Save my home address")}. You need it before you add a rental or earn a commission. Change it later under {B("Profile")}, at the top of the menu.',
            f'Next time, sign in at {U("carmacars.ca/sign-in")} with your Email and Password, then {B("Sign in")}.',
            f'Link expired? Press {B("Send me a new link")} on the page it opens, or ask an Admin for a password link.',
            f'Sign in with your phone: on {B("Profile")}, press {B("Add and verify my phone number")} and enter the 6-digit code we text you. Then press {B("Use my phone number instead")} on the sign-in page. Two-step sign-in still asks for your authenticator code.',
        ],
        shot=S('public/09-sign-in-phone', 0, 595, 390, 1180, pins=[(3, 372, 1041)]),
        note=f'Recommended: open your profile and press {B("Set up two-step sign-in")}. Scan the code with your authenticator app, '
             f'type the 6 digits and press {B("Continue")}. After that every sign-in asks for a code.')

    # ---------------------------------------------------------------- 1
    g.chapter('Your workday',
              'Every function works the same way: start on To do, take the oldest task, finish it, and check Today '
              'for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.',
              blurb='The menu, To do, task actions, Today, switching functions and your scorecard.')
    g.task('The menu', 'My work comes first: To do, Today at a glance, My scorecard and My sales. Customer service and Sales then have Live: Live chat, Live visitors and Game leads. Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.')
    g.table([
        ['Customer service', 'Bookings (Requests, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car), Renters (Messages, Find a renter, Review requests, Card coverage), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms)'],
        ['Sales', 'Bookings (Requests and offers, Chauffeur, Send an offer, Add a rental, New quote, Calendar, Find a car, Card coverage), Owners (Owner leads)'],
        ['Finance', 'Money (Payments by day, Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote, Find a car, Card coverage)'],
        ['Fleet', 'Field work (Field jobs, Field hours, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote, Find a car, Card coverage)'],
    ], head=['Function', 'Groups and pages'])
    g.task('To do', 'Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more. To do puts the most urgent first.')
    g.steps([
        'The top shows your function, today\'s date, how many things need you, your open, overdue and done-today figures, and your quickest actions.',
        f'{B("Next up")} is the one task to do now. Press its button to do it, or {B("Take it")} to make it yours.',
        'Your lanes group the work, for example Booking requests, Renter messages, Texts and calls, Live chat and Offers out. Each shows how many are waiting and how long the oldest has waited. Replies are timed against the 5-minute first reply target: past it the time turns red and says late. The most urgent lane comes first; press a lane to open it.',
        f'Customer service and Sales: {B("Waiting for a reply")} lists every request, renter message, missed call and chat, the longest wait first, each with its reply button. Sales also sees the commission ring and Follow-ups due, Fleet today\'s handovers, returns and moves and the cars right now, Finance Money today.',
        f'{B("Every open task")}: filter All, Mine, Unassigned or Waiting. Under More filters: Any time, Overdue, Due today or Escalated, and by type. Each row has a priority, the task, its record, when it is due and a live timer of how long it has waited.',
        f'Press {B("Take it")} to make it yours. Pressing the task opens the screen where it is done: a chat waiting for a person opens that chat, documents to check open the review, a request opens the booking. {B("Sheet")} opens the step-by-step procedure.',
        'Tasks close by themselves when their work is done elsewhere (an invoice paid or voided, a chat answered or closed); a day\'s opening and closing checks close at the end of that day.',
        f'On a computer, press {B("/")} to search (Find a renter; Sales: Find a car).',
    ], shot=S('va-cs/01-queue-desktop', 0, 60, 1440, 1000, pins=[(1, 700, 250), (2, 460, 550), (3, 600, 740)]))

    g.task('Work a task', 'Open the task. The buttons along the top move it on.')
    g.table([
        [B('Open the working screen'), 'Jumps to the booking, car or owner the task is about.'],
        [B('Done'), 'You finished it. It leaves the queue.'],
        [B('Waiting'), 'You are waiting on someone (a renter, an owner). It stays yours.'],
        [B('Escalate'), 'It needs an Admin. Add why.'],
        [B('Hand over'), 'Give it to someone else on the team.'],
        [B('Add a note'), 'Leave a note for whoever looks next.'],
    ], head=['Button', 'What it does'])
    g.tip('Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.')

    g.task('Today')
    g.steps([
        'Today lists pickups and returns, and what is due, for your function.',
        f'Press a booking number to open it. {B("To do")} takes you back to your tasks.',
    ], shot=S('va-cs/02-today-desktop', 0, 60, 1440, 760, pins=[(1, 330, 232)]))

    g.task('Documents to sign', 'Your staff agreement, when CarmaCars sends it.')
    g.steps([
        f'The queue shows "You have a document to sign". Press {B("Read and sign")}.',
        f'Check the key values at the top (your role, hours, rate and start date), then press {B("Read the PDF")} and read it.',
        f'Press {B("Sign")}. Your full legal name is your signature (or press {B("Draw instead")}). Several documents? One signature covers all of them. The signed copy stays on the same page.',
    ])

    g.task('Several functions? Switch with Working as')
    g.para(f'If you cover more than one function, {B("Working as")} above the menu lists them: Customer service, '
           'Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.')

    g.task('Your scorecard')
    g.steps([
        f'Open {P("My work", "My scorecard")}.',
        'By week shows each measure, its target and your result for each week.',
        'A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.',
        'The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.',
    ], shot=S('va-sales/05-scorecard-desktop', 0, 60, 1440, 420, pins=[(1, 60, 203), (2, 900, 270)]))

    # ---------------------------------------------------------------- 2
    g.chapter('Customer service',
              'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner '
              'forms. You are often the renter\'s first person.',
              blurb='Requests and offers, new quotes, renter messages, find a renter, owner forms, late returns.')
    g.para('Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, '
           'Owners and enquiries, Owner forms and Scorecard.')
    g.task('Answer a request')
    g.steps([
        f'Open {B("Requests")}. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.',
        'Waiting shows how long the renter has waited. Open the booking number.',
    ], shot=S('va-cs/03-requests-desktop', 0, 60, 1440, 700, pins=[(1, 390, 172), (2, 760, 270)]))
    g.steps([
        'On the Review tab, check the request: the car is free, the renter, the places.',
        f'Press {B("Adjust the booking")} to change the car, dates, places, price or extras, then {B("Save changes")}.',
        f'Add a message and press {B("Send the offer")}. Within your limit you can also use {B("Approve (within my limit)")} or {B("Approve and send the pay link")}.',
        f'Can\'t do it? {B("Decline")} with Reason and any alternative. Need to know more? {B("Ask the renter")}.',
    ], shot=S('va-cs/04-booking-review-desktop', 0, 60, 1440, 1060, pins=[(3, 1000, 300), (4, 1380, 1040)]))
    g.tip('Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.')
    g.para('Opening a request takes it for you: the others see "Being answered by" your name and cannot answer it until you send, decline or leave (20 minutes, renewed while you work). One someone else holds shows who, with the buttons off; it opens to you when their claim runs out, or ask an Admin to take it over. Sales: a request from the website shows "Opens to you at" a time for its first 15 minutes, and a To do task says when it opens; after that whoever opens it first answers it, customer service included.')

    g.task('An enquiry on an example car', 'Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.')
    g.steps([
        f'The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact. When a real car was free for those dates, the task names it after {B("Free:")} (the same make and model first, else the same class and body at a similar price), and the person was told we have a similar car and will confirm it within 2 hours.',
        f'Check the named car is still right for them (or find a real car of the same kind and price that is free for those dates), and make a {B("New quote")} for it.',
        'Call or email the person with the car and the price, then mark the task done.',
    ])
    g.tip('Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.')

    g.task('A request from a vehicle page', 'Every make, model, year and trim page (carmacars.ca/cars/toyota/rav4/2023/xle, for example) has Request it, for the exact car the person wants.')
    g.steps([
        'The request arrives as an enquiry with the car named in the message ("About the car: 2023 Toyota RAV4 XLE") and an Enquiry task in To do.',
        f'If we have that car, or one close to it, free for their dates, make a {B("New quote")} for it. If not, suggest the nearest car of the same kind and price.',
        'Reply by email or phone, then mark the task done.',
    ])
    g.tip('The pages say only what the data says: EPA fuel use, the Canadian trims and our own cars. Never promise equipment the page does not list.')

    g.task('A buyer lead from a /buy page', 'Every vehicle page has a for-sale twin (carmacars.ca/buy/toyota/rav4/2023/xle) with "Find me this car", and twins for financing, detailing and body shop work with their own request: a name, an email or phone, and when.')
    g.steps([
        f'The lead is in {B("Owner leads")} (customer service: {B("Owners and enquiries")}), Buyer leads (kind buyer, finance, detailing or body shop), with the car and what they asked, and a To do line for Sales: A buyer asked us to find a car, Someone asked about financing or leasing a car, A detailing request, or A body shop request.',
        'If one of our cars of that kind is for sale (an Admin flags it with its price), offer it. If not, offer to rent them the car for a week first, and say what we can find. We do not lend or lease: on a financing question, say so and offer the rental. For detailing or body shop work, give a time and a price, and always offer a rental while their car is in (an insurance replacement rental when it is a claim). For mechanical work (a "Mechanical work to arrange" task: an oil change, brakes, tires, a tow and the like), CarmaCars does not do the work: book it with a trusted shop or recommend one, never promise the shop\'s price or time, and offer a rental while their car is in.',
        f'Press {B("Take it")}, then {B("Update")} as you go: contacted, qualified, converted or closed with the reason.',
    ])
    g.tip('We mostly rent cars. Never say a car is for sale unless an Admin flagged it; the page shows it with its price when one is.')

    g.task('Send an offer to a caller', f'Open {B("Send an offer")} (or {B("Send an offer")} beside a car in Find a car). No request needed: one screen, and the renter has the link.')
    g.steps([
        f'Find the customer by name, phone or email, or press {B("Add a new customer")}: full legal name, mobile, email and date of birth. Already on file with that email or phone? Use them: never a second record.',
        'Choose the car (by car code, plate or name; each says Free or Not free), the dates and the places.',
        'The price: the rate sheet, a total or a rate per day, with the reason for a price you type. The deposit, discounts and fees are set by an Admin; customer service sets the Protection Plan price. Amounts I type, at the top of the price: Before tax, or After tax (HST included) to type what the renter pays, worked back to before tax for you. Or type the Total the renter pays (after tax): the rental charge is worked out from it.',
        'How the rental and the deposit are paid (card online, e-Transfer, cash, platform payout, the insurer; deposit by card hold, cash or e-Transfer), who found this client, the message, how long it is open (48 hours at most) and Email, Text or both.',
        f'Check the offer as the renter will see it on the right, then press {B("Send the offer")}.',
    ])
    g.tip(f'An offer that is out is changed in place: {B("Edit the offer")}, change it, then {B("Save and send the update")} or {B("Save without telling the renter")}. No need to withdraw it first.')

    g.task('New quote for a caller')
    g.steps([
        f'Open {B("New quote")}. Choose the Car, the Pickup and Return (at least 2 hours from now).',
        'Choose how the lead came in, then the caller\'s Full legal name, Email, Mobile and Date of birth.',
        'Set the Licence class and Damage cover, and note places, extras and what they asked.',
        f'Press {B("Create the request")}. It opens like any request; send the offer from there.',
    ], shot=S('va-cs/05-new-quote-desktop', 220, 60, 1440, 1320, pins=[(1, 1100, 256), (2, 1100, 586), (3, 1100, 976), (4, 1000, 1137)]), fig_w=3.4)

    g.task('Edit a booking, a fee or the renter', 'A booking that is confirmed, on trip or returned is edited directly; the renter\'s details are corrected from the booking.')
    g.steps([
        f'Overview, {B("Edit the booking")}: the return (extend or shorten), the car, the rental charge, each fee, the kilometres and the note. Tick {B("Email the renter what changed")}, or leave it off for a silent correction.',
        f'Money tab, Fees, {B("Change or add a fee")}: a fee forgotten (the young driver fee shows its price for the dates) or a charge of its own.',
        f'What is open shows at once: {B("Email a pay link")} or {B("Text a pay link")} for exactly that amount, or record cash or an e-Transfer ({B("Record a payment")}, For: the rental and fees).',
        f'{B("Edit renter")}: a wrong email, phone, name, licence or address. A new email is their sign-in at once.',
        f'The same renter twice? Under the renter, Possible duplicates: {B("Merge into this record")} moves everything of the other record here.',
    ])
    g.tip('Each edit is recorded with your name, the time, the reason and the before and after.', label='Good to know')

    g.task('Renter messages and Find a renter')
    g.steps([
        f'{B("Renter messages")} lists the latest messages with their booking. Open the booking to reply, then press {B("Send")}.',
        f'{B("Find a renter")}: search by name, email, phone or booking number.',
        f'To open a renter\'s private details, press {B("Open with a reason")}. The reason is kept in the access log.',
    ], shot=S('va-cs/06-messages-desktop', 0, 60, 1440, 320, pins=[(1, 470, 186)]))

    g.task('Add a car for an owner', f'Open {P("Owners", "Add a car for an owner")} (fleet: under Cars). You enter everything for the owner; they never fill in the application.')
    g.steps([
        'The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.',
        'The car: type the VIN. The car is looked up at once and shown in one line with the year, make, model, trim and details (Edit if something is wrong). No VIN at hand: add it by its plate and choose the year, make and model. Tap the colour and check the class. Upload the ownership permit, the insurance slip and the lender\'s information if you have them. Photos are optional.',
        'Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.',
        'Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.',
        f'Press {B("Add the car and send to an Admin")}. The application waits in the Admin\'s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.',
    ])
    g.task('Owner forms (Forms C and D)')
    g.steps([
        f'Open {B("Owner forms")}. Each row is a scan an owner uploaded, with the witnesses and the status.',
        'Press Open to read the scan. Check every page is there and signed, with each witness\'s signature and name.',
        f'Press {B("Approve")}, or {B("Send back")} with What to fix (the owner reads this).',
    ], shot=S('va-cs/08-owner-forms-desktop', 0, 60, 1440, 360, pins=[(2, 988, 170), (3, 1105, 170)]))

    g.task('A rental agreement signed on paper')
    g.steps([
        f'Open the booking. Under Signed on paper, press {B("Record paper signature")}.',
        'Choose the Rental agreement, or the booking change the renter signed.',
        'Check Signed by and Date signed, and upload the scan of every signed page.',
        f'Press {B("Record signature")}. It counts as signed, and the renter is not asked to sign again.',
    ])

    g.task('Signatures on the spot, or by link', 'A renter or an additional driver who has not signed yet.')
    g.steps([
        f'On the booking, press {B("Sign now on this device")}. Confirm the name and that you saw the original licence, then {B("Hand the device to")} the signer.',
        f'Or press {B("Email the signing link")} or {B("Text the signing link")}: they sign on their own phone.',
        'The licence comes first: the renter uploads it from the request, and the offer cannot be accepted without it.',
    ])
    g.task('The booking\'s rental agreements', 'The Rental agreements card keeps both agreements in step with the booking.')
    g.steps([
        'Any change after signing makes a new version by itself. A change to the dates, the price, the car, the drivers or the coverage waits for the renter\'s signature: they get the link by email and text, and the card says "Agreement v3 waiting for signature".',
        f'{B("Resend the signing links")}, or press the button with their first name beside it to have them sign on your device.',
        f'Fields still blank (a licence expiry, an insurer\'s policy number) are listed: type them and press {B("Save the missing fields")}. Check-out stops on a field a claim needs until it is filled or an Admin overrides.',
        'Every signature: a code to the signer\'s phone or email, the key terms initialled, three consents, a drawn signature.',
    ])

    g.task('Check renter documents', 'The renter\'s licence photos, selfie and proof of coverage, before the handover.')
    g.steps([
        f'Open the task "identity documents or coverage proof to review", or open the booking: {B("Review")} shows the documents of any booking being arranged or under way, with no task needed.',
        'Every licence image, selfie and proof of coverage of the booking is on one screen, with what to check written once above them: the name and date of birth, class G2 or G and valid past the return, the selfie matches, the coverage is active to the return date.',
        f'One is wrong? Open {B("Reject this one")} under it, type the reason the renter reads and press {B("Reject")}.',
        f'Then press {B("Approve all")}: everything still waiting is approved at once (the Protection Plan too). A document the system refuses is named with the reason; the rest are approved.',
    ])
    g.tip('Each opening is logged. An Admin can do the same from Admin > To do. Field staff review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from their My jobs: the booking history says the role, field.')

    g.task('Which credit cards include rental car coverage?', f'Renters ask this often. {P("Renters", "Card coverage")} (every function has it under Rentals or Bookings) is your quick reference: what to say, what to check, and the list.')
    g.steps([
        f'Send the renter {U("carmacars.ca/credit-card-rental-coverage")}: each card\'s car value limit (MSRP), longest rental, key exclusions, its official guide and the day we last checked it.',
        'Ask which car they want. Most Canadian cards stop at a car priced $65,000 or $85,000, and many luxury models are priced higher. Give them the car\'s model year and trim so they can check.',
        'Never tell a renter they are covered. Their card\'s issuer decides that: ask them to call the number on the back of their card about this car and these dates. CarmaCars does not decide claims.',
        'Over the limit, an excluded make, a debit card or a longer rental than the card allows: offer OPCF 27 on their own auto policy or the CarmaCars Protection Plan.',
    ])
    g.tip('A card marked Unverified came from a published summary, not the issuer\'s guide. Something wrong or out of date in the list? Tell an Admin: they correct it in Settings > Card coverage.')

    g.task('Review requests', f'Renters are asked for a review by email and text after each trip. {P("Renters", "Review requests")} shows the ones on hold and the Google reviews to match.')
    g.steps([
        'On hold: the booking has a charge that is not settled or waived yet (late return, kilometres, fuel, cleaning, smoking, damage, tolls) or an open incident. It leaves the list by itself once the charges are settled or waived.',
        f'The renter should be asked now anyway? Press {B("Send anyway")}. Should never be asked? Press {B("Do not ask")}.',
        f'Google reviews: a possible match to a renter shows "possible match". Press {B("Confirm")} if it is them, {B("Not this renter")} if not, or {B("Match to a booking")} with the booking number.',
        f'On a booking, the card Review requests has {B("Ask for a review")} (for example after a call that went well) and {B("Mark reviewed")} when the renter says they already left one.',
    ])
    g.tip('Never offer anything for a review and never ask only happy renters: everyone gets the same message and the same Google link.')

    g.task('A change to a confirmed booking')
    g.para('On a booking\'s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, '
           f'write the reason, press {B("Preview the price")}, then {B("Send to the renter")}. The renter has 48 hours to accept and sign the '
           'amendment. You also send a new signing link to an additional driver from the booking screen.')

    g.task('A late return')
    g.para('A booking past its return time shows the late return panel. Work it in order:')
    g.table([
        [B('Log a call'), 'Record each call to the renter and what they said.'],
        [B('Send T13'), 'The first late notice email.'],
        [B('Send T14 (final notice)'), 'The final notice.'],
        [B('Request disable'), 'Ask an Admin to approve disabling the car.'],
        [B('Open an incident'), 'When the car is not coming back as planned.'],
    ], head=['Button', 'When'])

    # ---------------------------------------------------------------- 3

    g.chapter('Chauffeur requests',
              'Customer service and Sales handle the chauffeur requests sent from carmacars.ca/chauffeur, and answer questions about the partner cars on the site.',
              blurb='Quote and confirm a chauffeur request; partner cars with insurance included or no credit card needed.')
    g.task('Quote a chauffeur request', 'A new request is a task in your queue: Chauffeur request CH-1001, with the vehicle, the date, the hours and the client\'s contact.')
    g.steps([
        f'Open {B("Chauffeur")} from the task (or the menu). Find the request by its number.',
        'Check the vehicle and the driver with the partner for that date and time.',
        f'To change the vehicle or the hours, press {B("Change")}. The quote is worked out again: 2 hours at the 2-hour rate, 3 hours or more at the 3+ hour rate for every hour, then HST.',
        f'Send the quote line to the client by email or phone. Press {B("Quoted")} and write how you sent it.',
        f'When the client agrees and the payment is arranged, press {B("Confirm")}. After the trip, press {B("Completed")}.',
    ])
    g.tip('The minimum is 2 hours. The rates on the site are guideline rates: the price is confirmed in the quote.')
    g.task('Partner cars: insurance included, no credit card', f'Some partner cars say {B("Insurance included: no personal auto policy needed")} and {B("No credit card needed: debit accepted")} on their page.')
    g.steps([
        'On these cars the renter does not choose a coverage option: the booking shows "insurance included with the car", already confirmed. There is no proof to review.',
        'The renter may pay with a debit card in their own name. A prepaid card is still refused.',
        'The deposit, the licence and selfie checks and the ages are the same as on every car.',
        'Partner cars without a confirmed model year say "Year confirmed when you book". An offer cannot be sent until an Admin confirms the year: ask an Admin.',
    ])

    g.chapter('Finance',
              'You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips.',
              blurb='Payments, deposits and refunds, tolls and tickets, reconciliation and Turo trips.')
    g.para('Your rail: Queue, Today, Payments, deposits, refunds, Tolls and tickets, Reconciliation, Turo trips, Find a renter, '
           'Calendar and Scorecard.')
    g.task('Your queue', 'Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.')
    g.figure(S('va-finance/01-queue-desktop', 210, 465, 1440, 1405, pins=[(1, 460, 693)]),
             note='The lanes show what Finance handles: payments to fix, refunds waiting, tolls and tickets, deposits to settle and owner statements. Money today counts them below.')

    g.task('Payments by day', f'{B("Payments by day")} is your day in one screen: every payment and refund, by method, with the cash drawer and the refunds to decide.')
    g.steps([
        f'Choose From and To (today by default) and tick the methods you want (card, e-Transfer, cash, cheque, platform payout, insurer and others; none ticked shows all), then press {B("Show")}.',
        'Totals by method: received, refunded and net. Each day: the same by method, the cash expected in the drawer (cash received less cash given back) and the cash counted.',
        f'At the end of the day count the drawer and press {B("Record the count")}. The difference shows "balanced", or "over" or "short" with the amount.',
        f'Refunds waiting: every refund asked for anywhere (a cancellation, a booking, Finance), with the policy maths (paid, the tier, the percentage back, what is kept). Press {B("Approve")} or {B("Decline")} with the reason in the same row; above your limit it says an Admin approves. Approved: {B("Issue the refund")}.',
        f'{B("Export CSV")} gives the same rows for the bank or the bookkeeper: refunds as negative amounts, holds marked as not money in.',
    ])

    g.task('Payments, deposits, refunds')
    g.steps([
        'Failed payments: each with the purpose, amount and the bank\'s reason.',
        'Deposits to take before pickup, and deposits due back.',
        f'Refunds in progress. Press {B("Request the refund")} and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then {B("Issue the refund")}.',
        'Owner invoices that failed, and owner statements to prepare.',
    ], shot=S('va-finance/02-money-desktop', 210, 60, 1440, 925, pins=[(1, 340, 582), (2, 1100, 247), (3, 1110, 352), (4, 345, 457)]), fig_w=4.0)

    g.task('A payment received another way', 'An owner or renter paid by e-Transfer, cheque, cash or bank transfer.')
    g.steps([
        f'Owner invoice: on {B("Payments, deposits, refunds")}, find it under Owner invoices owing and press {B("Record payment")}.',
        f'Renter: beside the failed payment, press {B("Paid another way")}. Or open the booking\'s Money tab: under Money by part press {B("Record a payment")}, choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid, then {B("Record it")}.',
        'Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.',
        f'Add the proof if you have it (a screenshot or a photo of the cheque), then press {B("Record payment")}.',
    ])
    g.para('The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. '
           'Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.')
    g.para('Each month\'s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.')
    g.task('Cards, holds and deposits given back', 'On the booking\'s Money tab.')
    g.steps([
        f'{B("Charge the saved card")}: a later charge (extra kilometres, fuel, damage, a late return) with the reason on the renter\'s receipt, or the deposit of a rental over 7 days.',
        f'A deposit hold: {B("Capture the hold")} for all of it, with the reason. A part capture (the rest is released) or {B("Release the hold")} waits for the settlement while the car is out, inside the toll window or while something is open; an Admin may do it with the reason.',
        f'A deposit taken in cash or by e-Transfer is given back the same way: the task Give the deposit back the way it came; then press {B("Returned")} with the reference or receipt number.',
    ])

    g.task('Settle a deposit', f'The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking\'s Money tab, under Deposit, press {B("Settle the deposit")}. Issue the Check-in statement first.')
    g.steps([
        'The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.',
        'Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.',
        'Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.',
        f'Damage: an Admin keeps the whole deposit ({B("Keep the whole deposit (damage)")}) or bills a damage charge up to the $2,500 deductible. Ask an Admin, with the photos.',
        f'Press {B("Settle")}. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.',
    ])
    g.tip('A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.', label='Good to know')

    g.task('Read a toll notice')
    g.steps([
        f'Open {B("Tolls and tickets")} and press {B("Read a notice")}.',
        'Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.',
        f'Press {B("Read it")}. Then check each line beside the notice and fix what was read wrong.',
        f'Press {B("Checked against the notice")} on each line ({B("Leave out")} to skip one), then {B("Save as checked")} and {B("Confirm and import")}.',
    ], shot=S('va-finance/04-tolls-read-desktop', 210, 60, 1440, 640, pins=[(2, 450, 316), (3, 260, 436), (4, 260, 580)]))
    g.tip(f'In the work queue, {B("Match again")} retries the match after a fix, and {B("Dispute")} marks a notice you think is wrong. '
          'Renters matched with high confidence are charged at import, with the notice and our fee.')
    g.figure(S('va-finance/03-tolls-desktop', 210, 120, 1440, 660, pins=[(1, 500, 186)]),
             note='The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice\'s plate, date, amount and match.')

    g.task('Reconciliation and Turo trips')
    g.steps([
        f'{B("Reconciliation")}: press {B("Record a processor payout")}, then {B("Match")} it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.',
        f'{B("Turo trips")}: press {B("Add a trip")} for one trip, or paste CSV rows and press {B("Import")}.',
    ], shot=S('va-finance/06-turo-desktop', 210, 60, 1440, 600, pins=[(2, 1380, 140)]))

    # ---------------------------------------------------------------- 4
    g.chapter('Fleet',
              'You keep the cars moving: field jobs, daily checks, photo reviews after returns, and the listing '
              'pipeline with its duplicate check and plate covering.',
              blurb='Field jobs, daily checks, photo reviews, similar cars and listings.')
    g.para('Your rail: Queue, Today, Field jobs, Field hours, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter '
           'and Scorecard.')
    g.task('Schedule field jobs', 'Every confirmed booking gets its handover (or delivery) and return (or pickup) jobs by itself, at the booking\'s times and place, given to the field staff member with the fewest jobs that day. You check and change them.')
    g.steps([
        'Jobs, next three days: each with its place, its field staff and whether they acknowledged it. "Made from the booking" marks the ones made by themselves; when the booking moves, they move too, unless you changed them.',
        f'Change a job with {B("Assign")}, {B("Reassign")}, {B("Move")} (time and place) or {B("Cancel")}.',
        f'Handovers and returns without a job (when the automatic jobs are off, or one was cancelled) are listed first: press {B("Schedule")}, the place filled in from the booking.',
        'An Admin turns the automatic jobs or the assignment off in Settings > Program.',
    ], shot=S('va-fleet/02-field-jobs-desktop', 210, 60, 1440, 625, pins=[(1, 430, 350)]), fig_w=4.3)

    g.task('Field hours', 'Field staff clock in and out on their phones. You see who is clocked in and every shift of the two-week pay period, and you fix what they cannot.')
    g.steps([
        f'Open {B("Field hours")}. {B("Clocked in now")} lists who is on, since when. {B("Earlier period")} and {B("Later period")} move between pay periods.',
        f'Someone forgot to clock out: press {B("Clock out for them")}, set the time they finished and write the reason.',
        f'Someone forgot to clock in, or a time is wrong: {B("Add hours")} enters a shift, {B("Change")} fixes one and {B("Remove")} takes one out. Each needs a reason; the change is kept in a log with what it was before.',
        'Once an Admin approves the pay run of a period, its shifts are locked: ask the Admin. You see hours only, not rates or pay.',
    ])

    g.task('Daily checks', 'Twice a day: the opening check by 9:00 and the closing check by 18:00.')
    g.steps([
        f'Open {B("Daily checks")} and choose {B("Opening check")} or {B("Closing check")}.',
        'Each line shows what was found. Tick OK, or Problem with a note.',
        f'Press {B("Save the opening check")} (or {B("Save the closing check")}). You can save it again.',
    ], shot=S('va-fleet/03-daily-checks-desktop', 210, 60, 1440, 880, pins=[(1, 290, 186), (2, 760, 404), (3, 1000, 831)]))

    g.task('Check a car out or in', 'Fleet, Sales and Customer service check cars out and in from the booking.')
    g.steps([
        f'On a confirmed booking press {B("Check out (pickup)")}; on a booking on rent, {B("Check in (return)")}. Today lists the ones due, each with its button.',
        'The checklist field staff use opens: readings (km and fuel or charge), the photo set with the plate and the gauges, damage close-ups and both signatures.',
        f'Afterwards press {B("Photo report")}: times, Late by, kilometres, fuel, photos and the return charges. Fleet waives a charge with {B("Waive")} and a reason.',
    ])

    g.task('Photo reviews after a return')
    g.para(f'After each return, the field photo set waits under {B("Photo reviews")}. Compare it with the pickup set. '
           f'Press {B("Review done")}, or {B("Ask for a re-shoot")} if a photo is missing or unclear.')

    g.task('Similar cars', 'A possible duplicate never keeps a car off the site: it shows on the car\'s checklist until you decide. Only Same car takes it off.')
    g.steps([
        'Each flag shows the car, what it looks like (same VIN, plate, photo or specs) and the other car.',
        'Compare the permit, the plate and the photos.',
        f'Press {B("Not a duplicate")} with a note when they are different cars, or {B("Same car")} when they are.',
    ], shot=S('va-fleet/06-similar-cars-desktop', 210, 60, 1440, 520, pins=[(1, 500, 200), (3, 1376, 200)]))

    g.task('Rates and kilometres', f'From a listing, press {B("The car and its rates")}, or open the car from Field jobs.')
    g.steps([
        'Type the rates an Admin set. Only the daily rate is needed; the others follow from it when empty. The weekend rate is a price per day for each day that starts on a Friday or Saturday.',
        f'Keep {B("Use the defaults")} for the kilometres, or choose {B("Custom for this car")}.',
        f'Check What renters pay under the fields, then press {B("Save the rates")}. Rates, kilometres and deposit save together.',
    ])

    g.task('Listings and covering plates')
    g.steps([
        f'Open {B("Listings")}. A draft waiting shows Needs review. Open it.',
        'The copy is written by itself (change a line only if you must: it is then kept). Check the photos: on each public photo, cover the plate or mark it not visible.',
    ], shot=S('va-fleet/05-listings-desktop', 210, 60, 1440, 400, pins=[(1, 880, 227)]))
    g.steps([
        f'Press {B("Cover the plate")}. Check the suggested box; {B("Suggest the plate")} asks again.',
        'Drag over a plate to draw a box; drag a box to move it, its corner to resize it.',
        f'Choose {B("A CarmaCars plate")}, {B("Pixelation")} or {B("Blur")}, then {B("Save the covered photo")}.',
        f'No plate in the shot? {B("No plate visible on this photo")}.',
    ], shot=S('admin/11-plate-editor-phone', 0, 0, 390, 776, hdr=True, pins=[(3, 205, 612), (4, 195, 340), (5, 240, 482), (6, 168, 716)]))
    g.warn('The plate check never holds a car back: a photo whose plate is not checked stays private, and goes public by itself once it is covered or marked. The covered photo replaces the public one; the original is kept privately.')
    g.task('Publish now', 'Customer service and fleet publish a car themselves; nothing has to be finished first.')
    g.steps([
        f'Open the car from Listings or Field jobs. Its listing says why it is not on the site yet; press {B("Publish now")}. With no rates yet it uses the suggested rates (similar cars, else the class defaults).',
        'What is still open (paperwork, details, photos, No VIN yet for a car added by its plate, a possible duplicate) shows as warnings after Publish now and on the car. None of them stops publishing.',
        'New cars with their rates usually go on the site by themselves (Publish new cars automatically, on by default). A car taken off the site by staff waits for Publish now.',
    ])
    g.tip('A car not on the fleet insurance policy yet can be requested, offered and paid for, but never handed over until the insurer confirms it. Requests and offers for such a car show a warning.')

    g.task('Calendar sync with Turo and other platforms', f'{P("Cars", "Calendar sync")}: a car listed on Turo or Getaround must never be booked twice.')
    g.steps([
        'Turo has no calendar link: Turo\'s trip emails come in by themselves, find their car by themselves (Turo car number, plate, VIN, year, make, model, trim, colour, what earlier emails taught) and block it with the turnaround. Nothing to set up per car.',
        f'An email the reader cannot place waits as "Which car is this?": press {B("Which car is this?")} and press the right car (best guesses first). It is remembered for that car\'s next emails. If the dates or trip number are missing: {B("Add as a Turo trip")} (choose the car, check the dates) or {B("Dismiss")}. A trip whose email did not come: {B("Add a Turo trip")} on the car.',
        'Each Turo trip shows the guest\'s name and phone when Turo\'s email includes them. Contact a Turo guest only about their trip, never with promotions.',
        f'Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car\'s Turo calendar, then press {B("Done on Turo")}. Dates that changed or a booking cancelled here show the dates to free on Turo.',
        f'Getaround, Google Calendar or another platform with a calendar (iCal) link: open {B("Add a calendar link")}, choose the platform, paste it and press {B("Add the link")}. Copy the car\'s CarmaCars link for that platform with {B("Copy")} and paste it into the platform\'s calendar import.',
        'A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.',
    ])

    # ---------------------------------------------------------------- 5
    g.chapter('Sales',
              'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, '
              'and owner leads.',
              blurb='Requests and offers, new quotes and owner leads.')
    g.para('Your menu: To do, Today, My scorecard and My sales, then Requests and offers, Send an offer, Add a rental, New quote, Calendar and Owner leads.')
    g.task('Requests, offers and new quotes')
    g.steps([
        f'{B("Requests and offers")}: the same queue customer service works. Answer requests and follow offers out.',
        f'{B("Send an offer")}: one screen for a caller, sent at once, as in chapter 2. {B("New quote")} still makes a request to offer later.',
        f'An offer that is out: {B("Edit the offer")}, then {B("Save and send the update")}.',
    ], shot=S('va-sales/02-requests-desktop', 210, 60, 1440, 640, pins=[(1, 700, 405)]))
    g.tip('Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.')
    g.task('Check the renter\'s licence', 'Sales approve the renter\'s licence like customer service: the licence front, the licence back and the selfie. The proof of coverage and the Protection Plan stay with customer service and Admins.')
    g.steps([
        f'On {P("My work", "To do")}, {B("Licences to check")} lists each booking with an image waiting, the longest wait first. Press {B("Review the licence")}.',
        f'On a booking, the card {B("Renter licence")} has the same: press {B("Review the licence")}.',
        'Look at each image: the name and date of birth match the booking, class G2 or G, valid past the return, no alteration, the selfie matches the licence photo.',
        f'One is wrong? Open {B("Reject this one")} under it, type the reason the renter reads and press {B("Reject")}. The renter is told and asked for a new image.',
        f'Then press {B("Approve all")}: every image still waiting is approved at once. An image the system refuses is named with the reason.',
    ])
    g.tip('The booking history says who decided and the role, sales. Each opening of the images is logged and the links last one minute.')
    g.task('In person or remote', 'Every Sales person works in one of two modes, on the same Sales screens. An Admin sets yours; it shows at the top of To do and on My sales.')
    g.table([
        ['Commission', 'Under 50 rental days in the month 10%, from 50 days 15%, from 100 days 20%', 'Under 50 rental days 5%, from 50 days 10%, from 100 days 15%'],
        ['Credit', 'Walk-ins, handovers you close, partner visits and the rentals you source', 'Only the rentals you source. A website request you answer with the first offer during one of your blocks counts as yours. Walk-ins and partner deals earn nothing'],
        ['Hours', 'You choose', 'At least 20 hours a week of Thursday to Sunday afternoons (noon to 6 pm, Toronto time), replying within 15 minutes to the chats, texts and calls assigned to you'],
        ['Every day', 'Nothing set', 'Marketplace and classified reposts, social media DM replies, three follow-ups on every quote, long-term and business outreach'],
        ['Every month', 'Nothing set', '400 touches. Under 400 when the month ends, the month\'s rate is one tier lower: 15% becomes 10%, 10% becomes 5%, 5% becomes 2.5%'],
    ], head=['', 'In person (Toronto)', 'Remote (anywhere)'])
    g.task('Remote: your duties', f'On {P("My work", "To do")}, {B("Remote duties")} shows this month\'s touches against 400, today\'s checklist, the peak hours you scheduled this week and your reply time.')
    g.steps([
        'Most touches count by themselves: an offer you send, a message or text you send from the portal, a live chat you answer (once a day for each chat), a call or text from the phone line, an ad you post, a call or message to a car owner.',
        f'For anything else press {B("Log a touch")}: choose the type and add the link of the post, profile or listing if there is one.',
        f'The checklist ticks itself as the day\'s touches come in. Three follow-ups on every quote stays open while a deal of yours has fewer than three.',
        f'Under My availability choose this week or next, press {B("Add a block")} for each time you will be on, then {B("Save the week")}. Days already past stay as they were.',
        'A website request you answer with the first offer during a block is credited to you as sourced, even if you chose Entered for CarmaCars. Off your blocks it stays a claim for an Admin.',
    ])
    g.tip('An Admin can void a touch logged by mistake. Once an Admin approves a month, its mode, its rates and its touches no longer change; a refund can still lower the tier, as for everyone.')
    g.task('My sales', f'Open {P("My work", "My sales")}. It shows your own sales and commissions only.')
    g.steps([
        'Commissions comes first. Your rate depends on your mode and the rental days of the month: in person 10%, 15% from 50 days, 20% from 100; remote 5%, 10% and 15%. The bar shows your days against the target of 100, and says when your rate rises. By month gives each month in one line: the mode, the days, the rate and, for remote, the touches and any drop.',
        f'The tiles show this week: quotes created, offers sent, rentals added, bookings confirmed, conversion, booked revenue and follow-ups due. Press {B("By month")} for months, {B("By week")} for weeks.',
        'By week (or By month) lists each period with the same figures, newest first.',
        'Follow-ups due lists your open deals with what to do next: send the offer, follow up before the offer expires, or follow up while the renter signs and pays. Red means it is past due.',
        'Deals lists every booking you created, added or sent an offer on in the last 180 days, with its status and what it counts. Open a request, an offer or a rental you added from its number.',
    ])
    g.table([
        ['Credited to you', 'A quote you created, a rental you added, or a website request whose first offer you sent. An Admin can give a deal to someone else.'],
        ['Quotes created, offers sent, rentals added', 'Counted on the day they happened.'],
        ['Bookings confirmed, booked revenue', 'Counted on the day the booking was confirmed.'],
        ['Conversion', 'Of the deals credited to you in the period, the share confirmed so far.'],
        ['Booked revenue', 'The rental charge before tax, after discounts. A cancelled booking counts only what was kept; refunds come off.'],
        ['Rental days (Sales)', 'The days of the completed, paid rentals you sourced that end in the month. The month\'s tier applies to all of that month\'s rentals.'],
    ], head=['Figure', 'How it is counted'])
    g.tip('Sales commissions are approved after the month ends, when the month\'s tier is known. A refund that drops the month under a tier lowers every commission of that month; anything already paid comes off your next payment.')
    g.task('Owner leads')
    g.steps([
        'Owner leads: each enquiry with the name, contact, car and status.',
        f'Press {B("Take it")} to make it yours, then call the owner.',
        f'Press {B("Update")} to set the status. When you close a lead, say why.',
        'Owner applications, last 90 days, shows who applied and how far onboarding has come.',
    ], shot=S('va-sales/04-leads-desktop', 210, 60, 1440, 460, pins=[(1, 290, 166), (3, 1376, 236), (4, 400, 312)]))

    # ---------------------------------------------------------------- 5b
    g.chapter('Add a rental by hand',
              'Every function adds rentals that come in by phone, at the counter, from Turo, a partner, an insurer or '
              'someone you know. The rental is confirmed and on the calendar at once.',
              blurb='Choose the car and dates, find the renter, price it, record how it is paid.')
    g.task('Add a rental', f'Open {P("Bookings", "Add a rental")}. Your home address must be in your profile first: until it is, the page asks for it.')
    g.steps([
        f'At pickup with the renter? Press {B("Start at pickup")}: the renter\'s name and phone, the car, the kilometres and the fuel, then {B("Hold the car and finish later")}. The car is held for 2 hours and you get a task to finish it.',
        f'Nothing is required to save: the form is saved as a draft as you type ({B("Save draft")} saves at once). Unfinished rentals, on Today and on this page, opens a draft where it was left, on any device. Tick Hold the car while I finish to keep the car off the calendar while you type.',
        'Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.',
        'The dates decide the case, shown under them. Car already out with the renter? Enter the pickup as when it left: the rental is recorded as on trip, and anything still missing (signature, licence check, coverage proof, deposit) becomes a task. A rental that has already ended is recorded by an Admin.',
        'Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.',
        'The calendar and the price are checked by themselves once the car and the dates are in. The price comes from the rate sheet. You may add the extras, how damage is covered and an allowed promo code.',
        f'Quick start: {B("Phone")}, {B("Walk-in")}, {B("Turo or another platform")} or {B("Insurance replacement")} sets the usual choices.',
        'A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner\'s car not yet on the fleet insurance policy is added by an Admin only.',
        'Every line of the price can be changed where it stands (customer service and sales, while Program settings allow it): the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the kilometres a day; add a fee from the list or a charge of its own. The (i) beside each line says what it is. The rate-sheet price stays on the booking; a price far under it is flagged for an Admin, never refused. Know what the renter paid with tax? Choose After tax (HST included) under Amounts I type and type those amounts ("$270 after tax for the rental, $50 for the Protection Plan"), or type the Total the renter pays (after tax): the rental charge is worked out so the total is exactly that. The total shown is the total saved.',
        'Any length: past 30 days the monthly rate applies for each 30 days, and the monthly periods are listed. Each later period gets its own agreement, sent to the renter to sign a few days before it starts (Monthly periods on the booking; Send the agreement for the next period now if needed).',
        'Choose how the rent is paid (e-Transfer or cash received, card on file, payment link, platform payout, insurer billed later; the ways open to you are set by an Admin; paid in parts: Add another payment) and then how the deposit is paid (card hold, cash or e-Transfer with its reference). Before you save sums it all up. Signed on paper already? Choose it: a task asks for the scan. An insurance replacement with dates not known yet: untick Blocks the car\'s calendar and say why. Insurer billed later shows Charges to the insurer: type the rate a day of VLF, LDW, T&LDW, PAP/PEC or Waiver Saver that the insurer authorized (empty: none); each is the rate times the days, plus HST, billed to the insurer.',
        f'Under Who found this client, choose {B("I sourced this client")} or {B("Entered for CarmaCars")}.',
        f'Press {B("Add the rental")}. The renter gets the confirmation email unless you tick {B("Do not email the renter")}.',
        'A rental you add is credited to you and shows in My sales as a rental you added. If you sourced it, its commission shows there too.',
    ])
    g.tip('The renter signs the rental agreement in their portal before pickup. With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.')

    # ---------------------------------------------------------------- 5c
    g.chapter('Commissions',
              'Every function earns a commission on the rentals it sources: a renter you found yourself. Say so when you '
              'enter the rental, the quote or the offer.',
              blurb='I sourced this client, your rate, when it is earned, approved and paid.')
    g.task('Mark who found the client', f'Every rental, quote and offer you enter asks: {B("I sourced this client")} or {B("Entered for CarmaCars")}.')
    g.steps([
        f'Choose {B("I sourced this client")} when you found the renter yourself: someone you know, your own post or your own outreach.',
        f'Choose {B("Entered for CarmaCars")} when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.',
        'A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.',
    ])
    g.table([
        ['Sales', 'Commission only, with no base pay. By the rental days of the month, on all of that month\'s rentals: in person under 50 days 10%, from 50 days 15%, from 100 days 20%; remote 5%, 10% and 15%, one tier lower in a month under 400 touches (chapter Sales)'],
        ['Customer service, finance, fleet', '10%'],
        ['How much', 'The rate on the rental charge before tax, after discounts, with late extra days; never on delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off'],
        ['When earned', 'When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental'],
        ['Your home address', 'It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client'],
        ['Paid', 'After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed'],
    ], head=['', 'Commission'])
    g.tip('A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.')

    # ---------------------------------------------------------------- live visitors and live chat (0060)
    g.chapter('Live visitors and live chat',
              'Customer service and Sales see who is on the site now and answer the live chat. The CarmaCars assistant '
              'answers first; you take over whenever you want.',
              blurb='Who is on the site, how likely each visitor is to book, one-click actions, follow-ups, the chat inbox.')
    g.task('Live visitors')
    g.steps([
        f'Open {P("Live", "Live visitors")}. "Live now" counts who is on the site now, "Visitors today" the people seen today. The page refreshes by itself every 15 seconds; the menu shows how many hot visitors are on the site. Each visitor shows a booking likelihood from 0 to 100 (Hot, Warm or Cold); the most likely to book come first.',
        '"Why" gives the three strongest reasons, for example "Pickup tomorrow · Saw $320 for 3 days · Tapped to call". The badges are all the signals; the dots say how strong each is.',
        'Each visitor shows a name when known, otherwise "Visitor from Toronto, phone", the page and car they are on, how many others look at that car now, and this visit\'s pages.',
        f'Suggested: the next step and a message. Press {B("Invite to chat with this message")}, or {B("Edit the message")} first. Sales can {B("Offer a 10% discount code")} (one per visitor a week). {B("Assign to Sales")} hands the visitor to Sales with a task. When their dates are taken, {B("Suggest a similar free car")} writes the message for you.',
        f'Press {B("Pages")} for the whole visit. Press {B("Start a chat")} to write your own short friendly message and press {B("Send")}: the visitor sees it in a bubble.',
        'A hot visitor raises an alert at the top of the page. Each action shows on the visitor ("Invited by Lena, 2 min ago"), so check it before writing.',
    ])
    g.task('Follow-ups', 'Signals of known visitors raise tasks on To do with what to do, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours". Call or message, then mark the task done. A task closes by itself when the renter answers or pays. Follow-ups done count in My sales.')
    g.para('Renters also get one polite reminder email (and at most one more) when they leave an offer, the pay page or a change unanswered. '
           'Taking the follow-up task, a chat with you or a message from you stops these reminders: you are handling it.')
    g.task('Live chat')
    g.steps([
        f'Open {P("Live", "Live chat")}. The menu counts chats waiting for a person. Reply within 5 minutes.',
        'Choose a conversation. Beside it: the visitor\'s page, pages and signals, and the renter\'s bookings when known.',
        f'Press {B("Take over")} (or just write a reply): the assistant stops. Write and press {B("Send")} or Enter. The visitor sees when you type.',
        f'{B("Hand back to the assistant")} when you are done, or {B("Close")}. A visitor who gave an email gets a copy of the chat.',
        'Tick "Email me when a chat waits (while I am on shift)" or desktop alerts if you want them.',
    ])
    g.tip('Prices: send a quote from New quote, never a price from memory. If you handled the chat, choose "I sourced this client" on the quote; nothing is credited by itself.')

    # ---------------------------------------------------------------- the phone line (0085)
    g.chapter('Texts and calls',
              'Customer service and Sales answer texts to the CarmaCars number in the same place as live chat. Every call and text is kept with '
              'the renter, owner or lead it belongs to.',
              blurb='Reading and answering texts, suggestions, unknown callers and missed calls.')
    g.task('Answer a text')
    g.steps([
        f'Open {P("Live", "Live chat")} and press {B("Texts and calls")}. Unread texts and missed calls are counted on each number.',
        'Choose a number: calls and texts in order, and beside them who it is, with their bookings.',
        f'Write the text and press {B("Send text")}. It goes from the CarmaCars number.',
        f'{B("Suggest a reply")} writes a draft into the box. Read it and change it: it is never sent until you press Send text.',
    ])
    g.task('Unknown callers', f'Press {B("Unknown callers")}. Type the name if they told you and press {B("Create lead")}, or find the renter and press {B("Link to")} their name.')
    g.task('Missed calls', 'A missed call gives you the task "Missed call from ..." when you have Live chat or Texts and calls open; otherwise it waits in the customer service queue. Call back with the Call button, or text, then mark the task done. Quo itself texts the caller back, so do not send the same message again.')
    g.tip('A number that texted STOP gets no texts from us, booking texts included, until they text START. Prices go in a quote, never in a text from memory.')
    g.task('Email, text or both', 'Each renter and owner chooses how we reach them. Their page in Admin shows it under How we reach them; ask an Admin, or change it there if you can open the page. '
           'Texts need a phone they verified with a code. Your own choice is on your Profile, under Messages.')

    # ---------------------------------------------------------------- discount games (0066)
    g.chapter('Discount game leads',
              'Visitors who are not signed in play a quick game on the site and win a promo code. To get it they give a first name, an email '
              'and sometimes a mobile number. Customer service and Sales follow them up.',
              blurb='Game leads to call or email, the code they won, whether it is used, and the Sales task.')
    g.task('Game leads', f'{P("Live", "Game leads")}.')
    g.steps([
        'Each claim: when, the name (and "on the site now"), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.',
        f'Press {B("Call")} or {B("Email")}. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press {B("Contacted")}.',
        f'{B("Close")} with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.',
    ])
    g.para('A visitor who viewed 3 cars or more also raises a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request.'
           ' A visitor who wins another go plays a second game first; only the code they end with shows here.')
    g.para('People can win again: a day after their last code the game comes back on their next visit, and a new code is a new line with "2nd code of 2" under the name. '
           'It is the same person: one call covers both codes, and while their Sales task is open the new code is added to it instead of a second task. '
           'Each code is for one booking and never combined with another; an earlier code they have not used stays good until it ends.')
    g.tip('Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 '
          'off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.')
    g.task('Contact details typed into forms')
    g.para('The card "Typed into forms" above the game leads lists the name, email and phone people typed into a form on the site without sending it, '
           'with "On the site now" and "Email not confirmed". Call or email to help them finish. Only what they typed; no offers without their consent.')

    # ---------------------------------------------------------------- 6
    g.chapter('Add-ons',
              'Renters buy add-ons with a rental: seats, flowers, a chauffeur, an umbrella, a phone charger, a full tank. '
              'You add them in offers and rentals, confirm the ones that need it, and Fleet keeps the stock.',
              blurb='Add-ons in offers and rentals, confirming a chauffeur, Fleet tasks and stock.')
    g.task('In an offer or a rental you add')
    g.steps([
        'On the review screen of a request, under Add-ons, tick or count what the renter wants. The price on the right follows. Choose the hours for a chauffeur.',
        'Add-ons the renter asked for are already ticked. One waiting for confirmation (a chauffeur) is confirmed when you keep it and send the offer; untick it to remove it.',
        f'In {P("Bookings", "Add a rental")}, the Add-ons list sits under The rental: tick them before you press {B("Check the calendar and the price")}.',
        'Notice is yours to judge: you may add flowers with less than 24 hours if Fleet can do it.',
    ])
    g.task('After booking')
    g.steps([
        'The booking page shows the add-ons, paid or not, and any waiting for confirmation.',
        f'A renter asked for a chauffeur from their portal: you get a task. Press {B("Confirm and charge")} (the card on file is charged) or {B("Decline")}.',
        f'Press {B("Remove")} and give the reason to take one off. Unpaid, it goes; paid, a refund for it waits for approval.',
    ])
    g.task('Fleet: tasks and stock', 'Flowers and a chauffeur give Fleet a task to get them ready, due before pickup by their notice.')
    g.steps([
        f'Open {P("Cars", "Add-ons")}. Each add-on shows its price, its notice and how many are booked in the next 30 days.',
        f'For seats, umbrellas and chargers, type how many we have under In stock and press {B("Save")}. Renters cannot ask for more than are free for their dates.',
        'A confirmed booking with more than we have gives you an urgent task: find another or tell the renter.',
    ])
    g.para('Add-on revenue is CarmaCars\' own. It is never in a commission: your commission stays on the rental charge.')

    # ---------------------------------------------------------------- the assistant (0080)
    g.chapter('Assistant',
              'The assistant answers questions from live data and prepares changes for you. It works only through the same steps as the '
              'screens, with your own permissions: it cannot see or do anything you could not do yourself. Nothing changes until you confirm.',
              blurb='Ask about today, bookings, cars and money; send offers and add rentals; confirm the changes it prepares.')
    g.task('Open it', f'Press {B("Assistant")} at the top of the menu, or press Ctrl and / together (Cmd and / on a Mac). Esc closes it.')
    g.steps([
        'Type a question or what you want done, in your own words, and press Enter. Examples: "What needs doing today?", "Who has the Tesla?", '
        '"Is the Corolla free from 2026-11-02 to 2026-11-04?", "Find booking R-000123".',
        'Answers come as cards with links: open one to go straight to the screen.',
        'If something is missing or more than one thing matches, it asks and lists the choices. Press the one you mean.',
    ])
    g.task('Changes: a card to confirm')
    g.steps([
        'Ask for a change, for example "Record a $900 e-Transfer on INV-1053 dated 2026-10-15 reference CA12345".',
        f'The assistant shows a card: "Record a $900 e-Transfer on INV-1053 for Karan Vakil, dated Oct 15?". Read it, then press {B("Confirm")} or {B("Cancel")}.',
        'Confirmed, it runs the same step as the screen and its pop-up, with the same checks. If the step is not allowed for you, or a detail is wrong, it says why and nothing changes.',
        'Every change is in the audit log under your name, marked "via assistant". A card older than 30 minutes no longer runs: ask again.',
    ])
    g.para(f'Messages: ask it to draft a message to a renter or an owner. It writes the text; press {B("Copy")}, open the conversation and send it yourself.')
    g.task('Offers, rentals and what is owed (customer service and sales)')
    g.steps([
        'Send an offer: "Send an offer for the Corolla to jane@example.com, Nov 2 10:00 to Nov 4 10:00". A customer on file is found by name, email or phone; a new customer needs the full name, email, mobile and date of birth. '
        'Say "I found this client" when you did, so the booking counts for you.',
        f'The card shows the customer, the car, the dates, each price line, the HST, what is due at booking, the deposit, how it is paid and how the offer is sent, priced as {B("Send an offer")} prices it. '
        f'Press {B("Confirm")} to make and send it, or {B("Cancel")}.',
        'Add a rental the same way: "Add a rental of the Corolla for jane@example.com, Nov 2 10:00 to Nov 4 10:00, paid by e-Transfer ref CA123, deposit in cash". Amounts after tax are understood: "$270 after tax for the rental and $50 after tax for the Protection Plan", or "$320 total after tax".',
        'What is owed: "What does booking R-000123 owe?" shows the rental, fees and later charges still open, and the deposit. Finance sees it too.',
        'Only what your function may do from the screens is offered; the booking\'s history says it was made with the staff assistant, with your name.',
    ])
    g.tip('The assistant keeps 70% of the day\'s free AI allowance for itself, so it works all day. When the whole allowance is used, it says how much was used and that it is back at midnight, Toronto time. '
          'Everything still works from the screens and pop-ups.')
    # ---------------------------------------------------------------- maintenance
    g.chapter('Car maintenance',
              'Fleet keeps every car serviced: oil, tires, brakes, inspections and the registration. Finance bills what Fleet '
              'records. Recording a service resets its reminders and makes its bill.',
              blurb='The maintenance list, recording a service in one step, tires and swaps, readings, and billing.')
    g.task('What is due', f'Open {P("Field work", "Maintenance")} (Finance: {P("Money", "Maintenance bills")}).')
    g.steps([
        'Every car, most urgent first: overdue (red), due soon, no record yet (dashed), all OK.',
        'Your To do has one Service due task per car listing what is due. Open it: the car opens with the record pop-up.',
        'A car with no record yet has one task to record its last service. Enter what you know once.',
    ])
    g.task('Record a service')
    g.steps([
        f'Press {B("Record a service")} on the car (or {B("Record")} on one item of the car\'s Maintenance).',
        'Tick what was done, check the date and the odometer, type the shop, the cost before HST and the HST, and add the receipt.',
        'Who pays: the owner for an owner\'s car (deducted on their statement), CarmaCars for a company car, a claim, the renter, or no charge.',
        f'Leave {B("The bill is in: bill it now")} ticked, or untick it and press {B("Bill now")} on the record later.',
        f'Press {B("Record the service")}. The items done are OK again.',
    ])
    g.warn('Above your single limit the service is recorded and the timers reset, but an Admin bills it: you see "An Admin bills it".')
    g.task('Tires, swaps and readings')
    g.bullets([
        f'Under Tires: {B("Add a tire set")} (kind, size, brand, tread, made and bought dates, where it is stored), {B("Put on the car")} to swap.',
        'Ontario: winter tires on by December 1 (reminder from November 1), off after April 1. Tires are due soon at 4 mm of tread, overdue at 3 mm.',
        f'{B("Add a reading")} when you see the odometer. Handover, return and move readings come in by themselves.',
        'A car whose recorded safety inspection or registration has expired cannot be handed over until the renewal is recorded.',
    ])

    # ---------------------------------------------------------------- shared
    g.chapter('Shared tools',
              'Every function has the calendar and Find a renter. Use them to answer questions fast.',
              blurb='The calendar and Find a renter.')
    g.task('The calendar')
    g.steps([
        'Every car, its bookings, requests and blocks. The red line is now.',
        'Use the arrows, Today and the range to move around, or search by plate, booking or name.',
        f'Fleet and customer service can remove a cleaning block from its side panel ({B("Remove the block")}) when a car is ready sooner.',
    ], shot=S('va-cs/09-calendar-desktop', 210, 60, 1440, 860, pins=[(1, 950, 330), (2, 560, 200)]))
    g.task('Find a car', f'{P("Bookings", "Find a car")} (Finance and Fleet: {P("Rentals", "Find a car")}). A renter quotes the car code on the car\'s page (like CC-7F3A).')
    g.steps([
        'Type the car code, a plate, a VIN or the name. Each car shows its code, plate, status and its page on the site.',
        'In Add a rental, type the car code or plate in the box above Car to choose it.',
    ])
    g.task('Find a renter')
    g.steps([
        'Search by name, email, phone or booking number.',
        f'Opening a renter\'s private details asks for a reason ({B("Open with a reason")}). It is kept in the access log.',
    ], shot=S('va-cs/07-renters-desktop', 210, 60, 1440, 300, pins=[(1, 1050, 143)]))

    g.reference(
        nav_rows=[('To do', 'Next up, your lanes with their timers, then every open task'),
                  ('Today at a glance', 'Pickups, returns, what is due'),
                  ('Working as', 'Switch function (above the menu)'),
                  ('Customer service', 'Requests, New quote, Renter messages, Owner forms'),
                  ('Finance', 'Payments, Tolls and tickets, Reconciliation, Turo trips'),
                  ('Fleet', 'Field jobs, Field hours, Daily checks, Photo reviews, Listings, Similar cars'),
                  ('Sales', 'Requests and offers, New quote, Add a rental, Owner leads'),
                  ('Add a rental, New quote', 'Every function'),
                  ('My sales', 'Your commissions, quotes, offers, bookings and booked revenue'),
                  ('My scorecard', 'Your results by week')],
        top_tasks=[('Take a task', f'{P("My work", "To do")}, {B("Take it")}, then {B("Done")}'),
                   ('Send an offer', f'{P("Bookings", "Requests")}, the booking, then {B("Send the offer")}'),
                   ('Quote a caller', f'{P("Bookings", "New quote")}, then {B("Create the request")}'),
                   ('See your sales', f'{P("My work", "My sales")}, then {B("By week")} or {B("By month")}'),
                   ('Claim a client you found', f'{B("I sourced this client")} when you add the rental or send the offer'),
                   ('Review Forms C and D', f'{P("Owner forms", "Approve")}'),
                   ('Read a toll notice', f'{P("Tolls and tickets", "Read a notice")}'),
                   ('Issue a refund', f'{B("Request the refund")}, {B("Issue the refund")}'),
                   ('Schedule a field job', f'{P("Field jobs", "Schedule")}'),
                   ('Cover a plate', f'{B("Cover the plate")}, {B("Save the covered photo")}')],
        extra_problems=[('A task is above your limit', f'Press {B("Escalate")} and say why. An Admin picks it up.'),
                        ('Asked for a 6-digit code', 'Open your authenticator app. Lost your phone? Tell an Admin.')])
    return g
