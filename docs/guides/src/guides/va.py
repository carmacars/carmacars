from lib import Guide, S, B, P, U


def build():
    g = Guide(
        key='va', title='VA Portal Guide', short='VA',
        promise='Your queue, your tools and your targets, for every function.',
        cover_shot=S('va-cs/01-queue-phone', 0, 595, 390, 1350),
        audience='staff', signin_url='carmacars.ca/sign-in?next=/va', lands_on='Queue, the tasks of your function')

    g.start_page(
        who='CarmaCars assistants (VAs) in Customer service, Finance, Fleet and Sales. Read chapter 1, then the chapter '
            'for your function. If you cover more than one, read each of them.',
        need=['The invitation email from CarmaCars (the link works for 24 hours)',
              'A computer for your shift. The portal also works on a phone',
              'An authenticator app on your phone, if your Admin turns on two-step sign-in'],
        first_steps=[
            f'Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press {B("Save the new password")}.',
            f'You land in your portal, on {B("Queue")}, working as your main function.',
            f'Next time, sign in at {U("carmacars.ca/sign-in")} with your Email and Password, then {B("Sign in")}.',
            f'Link expired? Press {B("Send me a new link")} on the page it opens, or ask an Admin for a password link.',
        ],
        shot=S('public/09-sign-in-phone', 0, 595, 390, 1180, pins=[(3, 372, 1041)]),
        note=f'Recommended: open your profile and press {B("Set up two-step sign-in")}. Scan the code with your authenticator app, '
             f'type the 6 digits and press {B("Continue")}. After that every sign-in asks for a code.')

    # ---------------------------------------------------------------- 1
    g.chapter('Your workday',
              'Every function works the same way: start on Queue, take the oldest task, finish it, and check Today '
              'for pickups and returns.',
              blurb='The queue, task actions, Today, switching functions and your scorecard.')
    g.task('The queue', 'Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.')
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
        f'Press a booking number to open it. {B("Queue")} takes you back to your tasks.',
    ], shot=S('va-cs/02-today-desktop', 0, 60, 1440, 760, pins=[(1, 300, 160)]))

    g.task('Documents to sign', 'Your staff agreement, when CarmaCars sends it.')
    g.steps([
        f'The queue shows "You have a document to sign". Press {B("Read and sign")}.',
        f'Check the key values at the top (your role, hours, rate and start date), then press {B("Read the PDF")} and read it.',
        f'Press {B("Sign")}. Your full legal name is your signature (or press {B("Draw instead")}). Several documents? One signature covers all of them. The signed copy stays on the same page.',
    ])

    g.task('Several functions? Switch with Working as')
    g.para(f'If you cover more than one function, {B("Working as")} at the top of the rail lists them: Customer service, '
           'Finance, Fleet and Sales. Choose one; the rail, the queue and Today change to that function.')

    g.task('Your scorecard')
    g.steps([
        f'Open {B("Scorecard")} at the bottom of the rail.',
        'By week shows each measure, its target and your result for each week.',
        'A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.',
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
    g.tip('Aim to send the offer within 15 minutes of the request. That is the "Quote sent" measure on your scorecard.')

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

    g.task('Listings and covering plates')
    g.steps([
        f'Open {B("Listings")}. A draft waiting shows Needs review. Open it.',
        'Check the copy and photos. On each public photo, cover the plate or mark it not visible.',
    ], shot=S('va-fleet/05-listings-desktop', 210, 60, 1440, 400, pins=[(1, 880, 227)]))
    g.steps([
        f'Press {B("Cover the plate")}. Check the suggested box; {B("Suggest the plate")} asks again.',
        'Drag over a plate to draw a box; drag a box to move it, its corner to resize it.',
        f'Choose {B("A CarmaCars plate")}, {B("Pixelation")} or {B("Blur")}, then {B("Save the covered photo")}.',
        f'No plate in the shot? {B("No plate visible on this photo")}.',
    ], shot=S('admin/11-plate-editor-phone', 0, 0, 390, 776, hdr=True, pins=[(3, 205, 612), (4, 195, 340), (5, 240, 482), (6, 168, 716)]))
    g.warn('Publishing waits until every public photo is covered or marked. The covered photo replaces the public one; the original is kept privately.')

    # ---------------------------------------------------------------- 5
    g.chapter('Sales',
              'You turn enquiries into bookings and owners into fleet: requests and offers, quotes for callers, '
              'and owner leads.',
              blurb='Requests and offers, new quotes and owner leads.')
    g.para('Your rail: Queue, Today, Requests and offers, New quote, Owner leads, Calendar and Scorecard.')
    g.task('Requests, offers and new quotes')
    g.steps([
        f'{B("Requests and offers")}: the same queue customer service works. Answer requests and follow offers out.',
        f'{B("New quote")}: price a car for a caller and press {B("Create the request")}, as in chapter 2.',
    ], shot=S('va-sales/02-requests-desktop', 210, 60, 1440, 640, pins=[(1, 380, 172)]))
    g.task('Owner leads')
    g.steps([
        'Owner leads: each enquiry with the name, contact, car and status.',
        f'Press {B("Take it")} to make it yours, then call the owner.',
        f'Press {B("Update")} to set the status. When you close a lead, say why.',
        'Owner applications, last 90 days, shows who applied and how far onboarding has come.',
    ], shot=S('va-sales/04-leads-desktop', 210, 60, 1440, 460, pins=[(1, 290, 166), (3, 1376, 236), (4, 400, 312)]))

    # ---------------------------------------------------------------- 5b
    g.chapter('Add a rental by hand',
              'Customer service and Sales add rentals that come in by phone, at the counter, from Turo, a partner or an '
              'insurer. The rental is confirmed and on the calendar at once.',
              blurb='Choose the car and dates, find the renter, price it, record how it is paid.')
    g.task('Add a rental', f'Open {B("Add a rental")} on your rail.')
    g.steps([
        'Choose the car, the dates and the places. The check shows any clash with another booking or with the cleaning time after a trip. You cannot book over a clash: ask an Admin.',
        'Find the renter by name, email or phone, or add a new one with their name, email, phone, date of birth and licence. Add any other drivers.',
        f'Press {B("Check the calendar and the price")}. The price comes from the rate sheet. You may add the extras, the coverage and an allowed promo code; a price typed by hand is for Admins.',
        f'Choose Where it came from and how it is paid. The ways open to you are set by an Admin, such as {B("Paid another way")}, {B("Send a payment link")} or {B("Charge the saved card")}.',
        f'Press {B("Add the rental")}. The renter gets the confirmation email unless you tick {B("Do not email the renter")}.',
    ])
    g.tip('The renter signs the rental agreement in their portal before pickup. If they sign on paper at the counter, an Admin records it. A payment link keeps the booking waiting for payment.')

    # ---------------------------------------------------------------- 6
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
        nav_rows=[('Queue', 'Your function\'s tasks, oldest due first'),
                  ('Today', 'Pickups, returns, what is due'),
                  ('Working as', 'Switch function (top of the rail)'),
                  ('Customer service', 'Requests, New quote, Renter messages, Owner forms'),
                  ('Finance', 'Payments, Tolls and tickets, Reconciliation, Turo trips'),
                  ('Fleet', 'Field jobs, Daily checks, Photo reviews, Listings, Similar cars'),
                  ('Sales', 'Requests and offers, New quote, Owner leads'),
                  ('Scorecard', 'Your results by week')],
        top_tasks=[('Take a task', f'{P("Queue", "Take it")}, then {B("Done")}'),
                   ('Send an offer', f'{P("Requests", "booking", "Send the offer")}'),
                   ('Quote a caller', f'{P("New quote", "Create the request")}'),
                   ('Review Forms C and D', f'{P("Owner forms", "Approve")}'),
                   ('Read a toll notice', f'{P("Tolls and tickets", "Read a notice")}'),
                   ('Issue a refund', f'{B("Request the refund")}, {B("Issue the refund")}'),
                   ('Schedule a field job', f'{P("Field jobs", "Schedule")}'),
                   ('Cover a plate', f'{B("Cover the plate")}, {B("Save the covered photo")}')],
        extra_problems=[('A task is above your limit', f'Press {B("Escalate")} and say why. An Admin picks it up.'),
                        ('Asked for a 6-digit code', 'Open your authenticator app. Lost your phone? Tell an Admin.')])
    return g
