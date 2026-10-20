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
        ],
        shot=S('public/09-sign-in-phone', 0, 595, 390, 1180, pins=[(3, 372, 1041)]),
        note=f'Recommended: open your profile and press {B("Set up two-step sign-in")}. Scan the code with your authenticator app, '
             f'type the 6 digits and press {B("Continue")}. After that every sign-in asks for a code.')

    # ---------------------------------------------------------------- 1
    g.chapter('Your workday',
              'Every function works the same way: start on To do, take the oldest task, finish it, and check Today '
              'for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.',
              blurb='The menu, To do, task actions, Today, switching functions and your scorecard.')
    g.task('The menu', 'My work comes first: To do, Today, My scorecard and My sales (customer service and Sales also have Live visitors, Live chat and Game leads). Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.')
    g.table([
        ['Customer service', 'Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms)'],
        ['Sales', 'Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads)'],
        ['Finance', 'Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote)'],
        ['Fleet', 'Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote)'],
    ], head=['Function', 'Groups and pages'])
    g.task('To do', 'Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.')
    g.steps([
        'The top line shows your function and how many tasks are open.',
        'Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.',
        'Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.',
        f'Press {B("Take it")} to make it yours. {B("Sheet")} opens the step-by-step procedure.',
    ], shot=S('va-cs/01-queue-desktop', 0, 60, 1440, 700, pins=[(1, 200, 92), (2, 520, 172), (3, 460, 340), (4, 1320, 395)]))

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
    ], shot=S('va-cs/02-today-desktop', 0, 60, 1440, 760, pins=[(1, 300, 160)]))

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

    g.task('An enquiry on an example car', 'Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.')
    g.steps([
        'The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact.',
        f'Find a real car of the same kind and price that is free for those dates, and make a {B("New quote")} for it.',
        'Call or email the person with the car and the price, then mark the task done.',
    ])
    g.tip('Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.')

    g.task('New quote for a caller')
    g.steps([
        f'Open {B("New quote")}. Choose the Car, the Pickup and Return (at least 2 hours from now).',
        'Choose how the lead came in, then the caller\'s Full legal name, Email, Mobile and Date of birth.',
        'Set the Licence class and Damage cover, and note places, extras and what they asked.',
        f'Press {B("Create the request")}. It opens like any request; send the offer from there.',
    ], shot=S('va-cs/05-new-quote-desktop', 220, 60, 1440, 1320, pins=[(1, 1100, 256), (2, 1100, 586), (3, 1100, 976), (4, 1000, 1137)]), fig_w=3.4)

    g.task('Renter messages and Find a renter')
    g.steps([
        f'{B("Renter messages")} lists the latest messages with their booking. Open the booking to reply, then press {B("Send")}.',
        f'{B("Find a renter")}: search by name, email, phone or booking number.',
        f'To open a renter\'s private details, press {B("Open with a reason")}. The reason is kept in the access log.',
    ], shot=S('va-cs/06-messages-desktop', 0, 60, 1440, 320, pins=[(1, 470, 186)]))

    g.task('Add a car for an owner', f'Open {P("Owners", "Add a car for an owner")} (fleet: under Cars). You enter everything for the owner; they never fill in the application.')
    g.steps([
        'The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.',
        'The car: type the VIN and press Decode, then the details. Upload the ownership permit, the insurance slip and the lender\'s information if you have them. Photos are optional.',
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
    g.chapter('Finance',
              'You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips.',
              blurb='Payments, deposits and refunds, tolls and tickets, reconciliation and Turo trips.')
    g.para('Your rail: Queue, Today, Payments, deposits, refunds, Tolls and tickets, Reconciliation, Turo trips, Find a renter, '
           'Calendar and Scorecard.')
    g.task('Your queue', 'Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.')
    g.figure(S('va-finance/01-queue-desktop', 0, 60, 1440, 620, pins=[(1, 380, 314)]),
             note='The type filters show what Finance handles: collect upfront, debit failed, match toll, refund cancellation and review statements.')

    g.task('Payments, deposits, refunds')
    g.steps([
        'Failed payments: each with the purpose, amount and the bank\'s reason.',
        'Deposits to take before pickup, and deposits due back.',
        f'Refunds in progress. Press {B("Request the refund")}; above your limit it waits for an Admin. Then {B("Issue the refund")}.',
        'Owner invoices that failed, and owner statements to prepare.',
    ], shot=S('va-finance/02-money-desktop', 210, 120, 1440, 1180, pins=[(1, 340, 190), (2, 360, 324), (3, 340, 727), (4, 370, 896)]), fig_w=4.0)

    g.task('A payment received another way', 'An owner or renter paid by e-Transfer, cheque, cash or bank transfer.')
    g.steps([
        f'Owner invoice: on {B("Payments, deposits, refunds")}, find it under Owner invoices owing and press {B("Record payment")}.',
        f'Renter: beside the failed payment, press {B("Paid another way")}. Or open the booking\'s Money tab and press {B("Record a payment received another way")}.',
        'Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.',
        f'Add the proof if you have it (a screenshot or a photo of the cheque), then press {B("Record payment")}.',
    ])
    g.para('The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. '
           'Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.')
    g.para('Each month\'s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.')

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
    g.para('Your rail: Queue, Today, Field jobs, Daily checks, Photo reviews, Calendar, Listings, Similar cars, Find a renter '
           'and Scorecard.')
    g.task('Schedule field jobs')
    g.steps([
        'Handovers and returns without a job are listed first. Every booking needs one.',
        f'Press {B("Schedule")}: choose the kind, car, when, place, field staff and instructions.',
        'Jobs, next three days: each with its field staff and whether they acknowledged it.',
        f'Change a job with {B("Assign")}, {B("Reassign")}, {B("Move")} or {B("Cancel")}.',
    ], shot=S('va-fleet/02-field-jobs-desktop', 210, 60, 1440, 1240, pins=[(1, 400, 183), (2, 1180, 210), (3, 350, 870), (4, 1180, 1050)]), fig_w=4.3)

    g.task('Daily checks', 'Twice a day: the opening check by 9:00 and the closing check by 18:00.')
    g.steps([
        f'Open {B("Daily checks")} and choose {B("Opening check")} or {B("Closing check")}.',
        'Each line shows what was found. Tick OK, or Problem with a note.',
        f'Press {B("Save the opening check")} (or {B("Save the closing check")}). You can save it again.',
    ], shot=S('va-fleet/03-daily-checks-desktop', 210, 60, 1440, 880, pins=[(1, 290, 186), (2, 760, 404), (3, 1000, 831)]))

    g.task('Photo reviews after a return')
    g.para(f'After each return, the field photo set waits under {B("Photo reviews")}. Compare it with the pickup set. '
           f'Press {B("Review done")}, or {B("Ask for a re-shoot")} if a photo is missing or unclear.')

    g.task('Similar cars', 'A possible duplicate listing stops publishing until you decide.')
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
    g.warn('Publishing waits until every public photo is covered or marked. The covered photo replaces the public one; the original is kept privately.')

    g.task('Calendar sync with Turo and other platforms', f'{P("Cars", "Calendar sync")}: a car listed on Turo or Getaround must never be booked twice.')
    g.steps([
        f'Turo has no calendar link: Turo\'s trip emails come in by themselves and block the car with the turnaround. For each car on Turo, press {B("This car is on Turo")}, type its name exactly as Turo\'s emails show it and press {B("Save")}.',
        f'Under "Turo emails to check", an email the reader was not sure about: check the trip on Turo, then {B("Add as a Turo trip")} (choose the car, check the dates) or {B("Dismiss")}. A trip whose email did not come: {B("Add a Turo trip")} on the car.',
        f'Turo cannot read our calendar: under "Block on Turo", block each CarmaCars booking on the car\'s Turo calendar, then press {B("Done on Turo")}. Dates that changed or a booking cancelled here show the dates to free on Turo.',
        f'Getaround, Google Calendar or another platform with a calendar (iCal) link: open {B("Add a calendar link")}, choose the platform, paste it and press {B("Add the link")}. Copy the car\'s CarmaCars link for that platform with {B("Copy")} and paste it into the platform\'s calendar import.',
        'A double booking raises an urgent task for you and an email: move, swap or cancel one trip. A link that stops working raises a task after 3 failed reads: copy it from the platform again.',
    ])

    # ---------------------------------------------------------------- 5
    g.chapter('Sales',
              'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, '
              'and owner leads.',
              blurb='Requests and offers, new quotes and owner leads.')
    g.para('Your menu: To do, Today, My scorecard and My sales, then Requests and offers, New quote, Add a rental, Calendar and Owner leads.')
    g.task('Requests, offers and new quotes')
    g.steps([
        f'{B("Requests and offers")}: the same queue customer service works. Answer requests and follow offers out.',
        f'{B("New quote")}: price a car for a caller and press {B("Create the request")}, as in chapter 2.',
    ], shot=S('va-sales/02-requests-desktop', 210, 60, 1440, 640, pins=[(1, 380, 172)]))
    g.tip('Your first reply target is 5 minutes, the "Quote sent" measure on your scorecard. Follow every offer out before it expires.')
    g.task('My sales', f'Open {P("My work", "My sales")}. It shows your own sales and commissions only.')
    g.steps([
        'Commissions comes first. In Sales your rate depends on the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%. The bar shows your days against the target of 100, and says when your rate rises.',
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
        'Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.',
        'Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.',
        f'Press {B("Check the calendar and the price")}. The price comes from the rate sheet. You may add the extras, the coverage and an allowed promo code.',
        'A car tagged Listing not finished can be rented too: it stays off the public site. If it has no rates yet, type the rental charge for the whole rental and the reason. An owner\'s car not yet on the fleet insurance policy is added by an Admin only.',
        'To charge another price, type the rental charge and the reason. The rate-sheet price stays on the booking. A price far under the rate sheet is flagged for an Admin to review, but the rental is still added.',
        f'Choose Where it came from and how it is paid. The ways open to you are set by an Admin, such as {B("Paid another way")}, {B("Send a payment link")} or {B("Charge the saved card when the renter signs")}.',
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
        ['Sales', 'Commission only, with no base pay and no set hours. By the rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all of that month\'s rentals'],
        ['Customer service, finance, fleet', '10%'],
        ['How much', 'The rate on the rental charge before tax, after discounts, less refunds'],
        ['When earned', 'When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental'],
        ['Your home address', 'It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client'],
        ['Paid', 'After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed'],
    ], head=['', 'Commission'])
    g.tip('A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.')

    # ---------------------------------------------------------------- live visitors and live chat (0060)
    g.chapter('Live visitors and live chat',
              'Customer service and Sales see who is on the site now and answer the live chat. The CarmaCars assistant '
              'answers first; you take over whenever you want.',
              blurb='Who is on the site, buying signals, follow-ups, the chat inbox, take over and hand back.')
    g.task('Live visitors')
    g.steps([
        f'Open {P("My work", "Live visitors")}. Each visitor shows a name when known, otherwise "Visitor from Toronto, phone", the page and car they are on, and this visit\'s pages.',
        'Badges are buying signals: "Viewing spree: 6 cars in 10 minutes", "Opened offer CC-1042, not answered", "Left the pay page", "Started a request and stopped" and more.',
        f'Press {B("Pages")} for the whole visit. Press {B("Start a chat")}, write a short friendly message and press {B("Send")}: the visitor sees it in a bubble.',
    ])
    g.task('Follow-ups', 'Signals of known visitors raise tasks on To do with what to do, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours". Call or message, then mark the task done. A task closes by itself when the renter answers or pays. Follow-ups done count in My sales.')
    g.para('Renters also get one polite reminder email (and at most one more) when they leave an offer, the pay page or a change unanswered. '
           'Taking the follow-up task, a chat with you or a message from you stops these reminders: you are handling it.')
    g.task('Live chat')
    g.steps([
        f'Open {P("My work", "Live chat")}. The menu counts chats waiting for a person. Reply within 5 minutes.',
        'Choose a conversation. Beside it: the visitor\'s page, pages and signals, and the renter\'s bookings when known.',
        f'Press {B("Take over")} (or just write a reply): the assistant stops. Write and press {B("Send")} or Enter. The visitor sees when you type.',
        f'{B("Hand back to the assistant")} when you are done, or {B("Close")}. A visitor who gave an email gets a copy of the chat.',
        'Tick "Email me when a chat waits (while I am on shift)" or desktop alerts if you want them.',
    ])
    g.tip('Prices: send a quote from New quote, never a price from memory. If you handled the chat, choose "I sourced this client" on the quote; nothing is credited by itself.')

    # ---------------------------------------------------------------- discount games (0066)
    g.chapter('Discount game leads',
              'Visitors who are not signed in play a quick game on the site and win a promo code. To get it they give a first name, an email '
              'and sometimes a mobile number. Customer service and Sales follow them up.',
              blurb='Game leads to call or email, the code they won, whether it is used, and the Sales task.')
    g.task('Game leads', f'{P("My work", "Game leads")}.')
    g.steps([
        'Each claim: when, the name (and "on the site now"), email and phone, the prize, the code and whether it is used, marketing consent, and the cars and pages they viewed.',
        f'Press {B("Call")} or {B("Email")}. Help them pick a car and send a request; the code goes in the promo code box (on their own device it is filled in). Then press {B("Contacted")}.',
        f'{B("Close")} with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.',
    ])
    g.para('A visitor who viewed 3 cars or more also raises a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request.')
    g.tip('Without marketing consent, talk only about their request and the code they asked for: no other offers. The code takes up to $75 '
          'off the rental charge (a percentage), or $50 off a rental of 3 days or more, on one booking within 7 days.')

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
    g.task('Find a renter')
    g.steps([
        'Search by name, email, phone or booking number.',
        f'Opening a renter\'s private details asks for a reason ({B("Open with a reason")}). It is kept in the access log.',
    ], shot=S('va-cs/07-renters-desktop', 210, 60, 1440, 300, pins=[(1, 1050, 143)]))

    g.reference(
        nav_rows=[('To do', 'Your function\'s tasks, oldest due first'),
                  ('Today', 'Pickups, returns, what is due'),
                  ('Working as', 'Switch function (above the menu)'),
                  ('Customer service', 'Requests, New quote, Renter messages, Owner forms'),
                  ('Finance', 'Payments, Tolls and tickets, Reconciliation, Turo trips'),
                  ('Fleet', 'Field jobs, Daily checks, Photo reviews, Listings, Similar cars'),
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
