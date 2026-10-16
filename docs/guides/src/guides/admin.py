from lib import Guide, S, B, P, U


def build():
    g = Guide(
        key='admin', title='Admin Portal Guide', short='Admin',
        promise='Run every booking, car, owner and dollar of CarmaCars from one place.',
        cover_shot=S('admin/01-today-phone', 0, 595, 390, 1350),
        audience='admins', signin_url='carmacars.ca/sign-in?next=/admin', lands_on='Today, the Admin dashboard')

    g.start_page(
        who='CarmaCars Admins: the owner of the business and anyone an Admin invites with the Admin role. '
            'Admin sees and changes everything, and can open any other portal as one of its people.',
        need=['Your Admin email address. The owner\'s account is rent@carmacars.ca',
              'Access to that inbox (links work for 24 hours, once)',
              'A computer for most work. Admin also works on a phone, with the menu as one scrolling strip'],
        first_steps=[
            f'First time? Go to {U("carmacars.ca/reset-password")}, enter your Admin email and press {B("Send the link")}.',
            f'Open the email "Reset your CarmaCars password" within 24 hours and press {B("Choose a new password")}.',
            f'Type a New password of 8 characters or more and press {B("Save the new password")}. You land in Admin.',
            f'Next time, sign in at {U("carmacars.ca/sign-in")} with that email and password.',
        ],
        shot=S('public/11-reset-password-phone', 0, 595, 390, 1060, pins=[(1, 372, 846)]),
        note=f'A link that has expired or was already used opens "This link has expired" with {B("Send me a new link")}. '
             'Invited by another Admin? The invitation email works the same way.')

    # ---------------------------------------------------------------- 1
    g.chapter('Getting around Admin',
              'Admin opens on Today: what needs you now. The rail on the left groups every screen into '
              'Operate, Fleet, Money, Recover, People and Setup.',
              blurb='Today, the rail, keyboard shortcuts and your other portals.')
    g.task('Today', 'Start every shift here.')
    g.steps([
        'Alerts: site setup still to finish, failed scheduled jobs and email use. Each has a link to fix it.',
        'The tiles count requests waiting, offers out, late returns, failed payments and fleet use.',
        'Requests waiting, pickups and returns today, late returns and money this month.',
        f'Press {B("Work the requests")} to go straight to the queue, or {B("Calendar")} for the master calendar.',
    ], shot=S('admin/01-today-desktop', 0, 0, 1440, 1000,
              pins=[(1, 1395, 227), (2, 348, 400), (3, 715, 530), (4, 1160, 118)]))
    g.task('The rail', 'On a phone the rail becomes one scrolling strip at the top.')
    g.table([
        ['Operate', 'Today, Requests, Bookings, Calendar, Tasks'],
        ['Fleet', 'Vehicles, Listings, Similar cars, Bulk rates'],
        ['Money', 'Payments and refunds, Insurer invoices, Owner invoices, Owner debits, Owner statements, Payouts, Company statements, Expenses, Reconciliation'],
        ['Recover', 'Tolls and tickets, Damage, Incidents and claims'],
        ['People', 'Portals and sign-in, Staff, Owners, Owner forms, Investors, Reviews, Email, Audit log'],
        ['Setup', 'Settings'],
    ], head=['Group', 'Screens'])
    g.task('Keyboard shortcuts', 'Press g, then a letter. Press / to jump to the page\'s search box.')
    g.table([
        ['g t', 'Today', 'g v', 'Vehicles'],
        ['g r', 'Requests', 'g l', 'Listings'],
        ['g b', 'Bookings', 'g m', 'Money'],
        ['g c', 'Calendar', 'g o', 'Tolls'],
        ['g k', 'Tasks', 'g s', 'Settings'],
    ], head=['Keys', 'Opens', 'Keys', 'Opens'], cls='keys')

    # ---------------------------------------------------------------- 2
    g.chapter('People and access',
              'Let people in, help them back in when they are locked out, and see exactly what they see. '
              'Every step is recorded in the audit log.',
              blurb='Portals and sign-in, invitations, password links, View as, staff and scorecards.')
    g.task('Portals and sign-in', f'Open {P("People", "Portals and sign-in")}. Every portal has a card.')
    g.steps([
        f'Each card links to {B("Its sign-in page")}, the address to send that person.',
        'Choose a person in the list on the card.',
        f'Press {B("Open as this person")} to see that portal as they see it.',
    ], shot=S('admin/27-portals-desktop', 0, 0, 1440, 820, pins=[(1, 949, 248), (2, 836, 323), (3, 743, 374)]))

    g.task('Invite a person', 'Invitations work for every role. The person gets our invitation email and chooses a password.')
    g.steps([
        'Under Invite a person, choose the Role: Admin, Staff (assistant), Field staff, Owner on file or Investor on file.',
        'Fill in the Name and Email.',
        'For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.',
        f'Press {B("Invite")}. The link in the email works for 24 hours.',
    ], shot=S('admin/27-portals-desktop', 210, 880, 1440, 1240, pins=[(1, 441, 1027), (2, 825, 1027), (3, 441, 1120), (4, 330, 1196)]))
    g.tip('Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: '
          'Admin > Owners and Admin > Investors also have a one-click invite for a record without a sign-in.')

    g.task('Send a password link', 'For anyone who forgot their password or let their invitation expire.')
    g.steps([
        'Under People who can sign in, search by name or email.',
        f'On their row, press {B("Send password link")}. They get "Reset your CarmaCars password", valid for 24 hours.',
        f'{B("View as (...)")} on the same row opens their portal, read only.',
    ], shot=S('admin/27-portals-desktop', 210, 1260, 1440, 1700, pins=[(1, 1130, 1289), (2, 1049, 1386), (3, 1244, 1386)]))

    g.task('View as: see what someone sees')
    g.steps([
        'A red banner says "Viewing as Name (email), read only." on every page.',
        'Click around their portal. Nothing can be changed: every save is refused.',
        f'Press {B("Exit")} to come back. A view also ends by itself after 30 minutes.',
    ], shot=S('admin/28-view-as-desktop', 0, 0, 1440, 620, pins=[(1, 700, 28), (3, 1360, 28)]))
    g.warn('Can\'t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.')

    g.task('The audit log', f'{P("People", "Audit log")} shows who changed what, and when.')
    g.steps([
        'Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.',
        'Every View as is recorded (view_as_start), with the person viewed.',
        'Search by table, record id or value.',
    ], shot=S('admin/29-audit-desktop', 0, 0, 1440, 560, pins=[(1, 325, 174), (2, 562, 260), (3, 1290, 116)]))

    g.task('Staff and roles', f'{P("Settings", "Staff and roles")} (also under {P("People", "Staff")}).')
    g.steps([
        f'Invite staff here too: Role, Name, Email, Main function and Also covers, then {B("Invite")}.',
        f'Each row has {B("Send password link")}, {B("View as (...)")} and Limits (how much they may approve or refund).',
        f'Press {B("End access")} to close their staff portal at once. {B("Restore")} undoes it.',
    ], shot=S('admin/26-staff-desktop', 0, 0, 1440, 780, pins=[(1, 300, 460), (2, 1360, 676), (3, 1199, 722)]))

    g.task('Staff scorecards', 'See how each assistant is doing against the targets.')
    g.steps([
        f'On a staff member\'s row in Staff and roles, press {B("Scorecard")}.',
        'By week shows each measure (for example quote sent within 15 minutes) and the result for each week.',
        'A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.',
    ], shot=S('va-sales/05-scorecard-desktop', 210, 120, 1440, 470, pins=[(2, 470, 270)]))

    # ---------------------------------------------------------------- 3
    g.chapter('Requests, offers and bookings',
              'Every booking starts as a request. You check it, adjust it and send the offer. After that, the booking '
              'page holds the money, documents, changes and history.',
              blurb='Answer a request with an offer, run a booking, and propose a change.')
    g.task('The request queue', f'Open {B("Requests")}. The oldest waiting request is at the top.')
    g.steps([
        'Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.',
        'Waiting shows how long the renter has waited. Open a booking number to answer it.',
    ], shot=S('admin/02-requests-desktop', 0, 0, 1440, 820, pins=[(1, 267, 174), (2, 365, 260)]))

    g.task('Answer a request with an offer')
    g.steps([
        'The Review and offer tab shows the request as the renter sent it.',
        'Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.',
        'Price on the right updates as you change things.',
        f'Add a message, choose how long the offer stays open, then press {B("Send the offer")}.',
    ], shot=S('admin/03-booking-review-desktop', 0, 0, 1440, 1060,
              pins=[(1, 312, 174), (2, 288, 481), (3, 936, 481), (4, 1390, 1047)]))
    g.steps([
        f'Changed fields but not ready to send? Press {B("Save changes")}. The panel "The offer as the renter sees it" shows the result.',
        f'Can\'t do it? Press {B("Decline")} and fill in Reason and any alternative.',
        f'Need an answer first? Press {B("Ask the renter")} to send a question.',
    ], shot=S('admin/03-booking-review-desktop', 820, 1440, 1440, 2250, pins=[(5, 1390, 1712)]), fig_w=2.9)
    g.tip(f'After the offer is out: {B("Withdraw to edit")} takes it back, {B("Send again, later expiry")} gives the renter more time, '
          f'and {B("Renter approved by phone")} records a yes given on a call.')

    g.task('A booking', 'Open Bookings, then a booking number.')
    g.steps([
        'Tabs: Overview, Money, Changes, History, and Drivers and documents.',
        'Overview shows the trip, the renter, what is still missing for the handover, and the price.',
        'Open tasks for this booking, with the queue and the due time.',
        f'Top right: {B("Stop blocking the calendar")}, {B("Cancel for the renter")} and {B("Cancel by CarmaCars")}.',
    ], shot=S('admin/04-booking-desktop', 0, 0, 1440, 960, pins=[(1, 290, 230), (2, 500, 560), (3, 290, 700), (4, 1300, 176)]))

    g.task('Propose a change to a confirmed booking', 'The renter gets an email and answers on their booking. The calendar moves only when they accept.')
    g.steps([
        'Open the booking\'s Changes tab. Under Propose a change, set the new pickup, return or car.',
        'To price it by hand, type a New rental charge before tax. Leave it empty to use the car\'s rates.',
        'Write the Reason, for the renter. They read it.',
        f'Press {B("Preview the price")}, then {B("Send to the renter")}.',
    ], shot=S('admin/05-booking-changes-desktop', 210, 230, 1440, 760, pins=[(1, 369, 311), (2, 640, 392), (3, 822, 543), (4, 590, 618)]))
    g.tip('The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to '
          'their Card on File; a lower price raises a refund for your approval.')

    # ---------------------------------------------------------------- 4
    g.chapter('Calendars',
              'The master calendar shows every car, booking, request and block. Each car also has its own '
              'calendar and turnaround time.',
              blurb='The master calendar, moving bookings, blocks, cleaning time and a car\'s calendar.')
    g.task('The master calendar')
    g.steps([
        f'Move through time with the arrows and {B("Today")}, or pick a date.',
        f'Choose the range: {B("Today")}, {B("Week")}, {B("2 weeks")} or {B("Month")}. {B("Agenda")} shows a list instead.',
        'The legend: confirmed, on rent, request, offer, not blocking, block and Turo.',
        'Each row is a car. Bars are bookings and blocks; the red line is now.',
    ], shot=S('admin/06-calendar-desktop', 0, 0, 1440, 1000, pins=[(1, 337, 179), (2, 652, 179), (3, 465, 239), (4, 959, 330)]))
    g.task('Move a booking, add or remove a block')
    g.steps([
        f'To move a booking, drag its bar to the new car or time, then press {B("Confirm the move")}.',
        f'To block a car, double-click its row where the block starts, then press {B("Create the block")}. {B("New block")} at the top does the same.',
        f'To remove a block, open it and press {B("Remove the block")}.',
    ])
    g.tip('After every confirmed trip a cleaning block holds the car for its turnaround time. It follows changes and '
          'extensions and goes away with a cancellation. Remove it from the side panel if the car is ready sooner; that time is then free.')
    g.task('A car\'s own calendar', f'{P("Vehicles", "the car", "Calendar")}')
    g.steps([
        'The Calendar tab shows only this car, with its bookings and blocks.',
        f'Turnaround between trips on this car shows the time used. Press {B("Change")} to give this car its own time.',
    ], shot=S('admin/07-vehicle-calendar-desktop', 0, 0, 1440, 560, pins=[(1, 606, 174), (2, 740, 228)]))

    # ---------------------------------------------------------------- 5
    g.chapter('Fleet and listings',
              'Vehicles is the fleet. Listings is the pipeline that turns a car into a page on carmacars.ca: '
              'photos, copy, a duplicate check and a covered plate on every public photo.',
              blurb='Vehicles, the listing pipeline, similar cars and covering licence plates.')
    g.task('Vehicles')
    g.steps([
        'Filter by status and mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.',
        f'Search by plate, model or owner. {B("Bulk rate change")} changes rates of many cars at once.',
        'Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker.',
    ], shot=S('admin/08-vehicles-desktop', 0, 0, 1440, 900, pins=[(1, 267, 174), (2, 1203, 116), (3, 1060, 350)]))
    g.tip('The Tracker card on a car says "Coming soon": live location, the remote immobilize request and mileage from '
          'the tracker need the tracker company\'s connection first.', label='Coming soon')

    g.task('The listing pipeline', f'Open {B("Listings")}. A draft waiting for review shows Needs review.')
    g.steps([
        'Each row shows the car, plate, state, photos and the pipeline\'s progress.',
        f'Press {B("Start a listing")} to begin one for a car that has none.',
        'Open a car to review it.',
    ], shot=S('admin/09-listings-desktop', 0, 0, 1440, 560, pins=[(1, 771, 207), (2, 1255, 118), (3, 470, 207)]))

    g.task('Review a listing')
    g.steps([
        'Pipeline shows each step done, such as photo sizes, copy draft and backgrounds.',
        f'Similar cars on file lists possible duplicates. Press {B("Not a duplicate")} or {B("Same car")}. An open flag stops publishing.',
        'Check the copy: headline, description, features, questions, search title and description.',
        'Under Photos, each public photo shows its plate state: Plate not checked, Plate covered or No plate visible.',
    ], shot=S('admin/10-listing-review-desktop', 0, 0, 1440, 1100, pins=[(1, 297, 183), (2, 1240, 522), (3, 286, 1175), (4, 1078, 1175)]))

    g.task('Cover the licence plate', f'On each public photo press {B("Cover the plate")}. The editor opens.')
    g.steps([
        f'The editor suggests a box over the plate. Check it. {B("Suggest the plate")} asks again.',
        'Drag over a plate to draw a box. Drag a box to move it, or its corner to resize it.',
        f'Under Cover the plate with, choose {B("A CarmaCars plate")}, {B("Pixelation")} or {B("Blur")}.',
        f'Press {B("Save the covered photo")}. {B("Clear the boxes")} starts over.',
        f'No plate in the shot? Press {B("No plate visible on this photo")}.',
    ], shot=S('admin/11-plate-editor-desktop', 270, 90, 960, 793, hdr=False,
              pins=[(1, 563, 679), (2, 612, 300), (3, 300, 634), (4, 377, 679), (5, 395, 731)]), fig_w=3.6)
    g.tip('The covered photo replaces the public one; the original is kept privately. Keyboard: N adds a box, the arrows move it, '
          'Shift and the arrows resize it, Delete removes it.')

    g.task('Publish')
    g.steps([
        f'When every public photo is covered or marked, press {B("Approve and publish")}.',
        f'Or press {B("Approve, publish later")}, or {B("Send back")} with what to fix.',
    ])
    g.warn('Publishing waits for a plate decision on every public photo ("Cover the licence plate or mark it not visible on every '
           'public photo first"). Listings already live show "Plate not checked" until someone checks them.')

    # ---------------------------------------------------------------- 6
    g.chapter('Owners and onboarding',
              'Owners apply on the site. You approve them, set their terms, and check their forms. '
              'Their page shows everything about them in one place.',
              blurb='Applications, terms, an owner\'s page, sign-in help and Forms C and D.')
    g.task('Owner applications', f'{P("People", "Owners")}')
    g.steps([
        'Each owner shows their application, how many cars, and where onboarding stands.',
        f'{B("View as (owner portal)")} shows their portal. {B("Send password link")} helps them sign in.',
        f'Invite an owner on file: fill in Name and Email under Invite an owner, then press {B("Send invitation")}.',
    ], shot=S('admin/12-owners-desktop', 0, 0, 1440, 560, pins=[(1, 590, 240), (2, 539, 276), (3, 1114, 462)]))
    g.task('Approve an application and set terms')
    g.steps([
        f'Open the application and press {B("Approve and set terms")} (or {B("Set terms (standard grid)")}).',
        'The owner signs the agreements and pays the upfront invoice in their portal.',
        f'Paid another way? On the invoice, press {B("Record payment")} (see Paid and signed, below).',
    ])
    g.task('An owner\'s page', 'Open an owner from Owners. The details are in the right-hand column.')
    g.steps([
        'Upfront invoices: issue the first and last month\'s insurance fee for each car whose terms are set.',
        'Owner: address, sign-in, agreements, and what is still missing for the registry forms.',
        'Statements and payouts for this owner.',
        'Forms C and D, with a link to the review queue.',
        f'Further down: {B("View as (owner portal)")}, {B("Send password link")} and {B("Send a sign-in link to the owner portal")}.',
    ], shot=S('admin/13-owner-desktop', 1010, 280, 1420, 1310, hdr=False, pins=[(1, 1111, 325), (2, 1076, 619), (3, 1139, 1034), (4, 1097, 1290)]))

    g.task('Paid and signed', f'{P("People", "Owners")}, then {B("Paid and signed")}. What each owner still has to pay or sign, and how each item was done.')
    g.steps([
        'Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.',
        f'Open {B("Checklist and quick actions")}. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.',
        f'Paid by e-Transfer, cheque, cash or bank transfer? Press {B("Record payment")}. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.',
        f'Signed on paper? Press {B("Record paper signature")}. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.',
        'The same checklist sits at the top of each owner\'s page.',
    ])
    g.para('A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on <date>" in their portal. '
           'A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner\'s documents.')
    g.warn(f'Recorded the wrong thing, or a cheque bounced? Press {B("Void")} beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.')

    g.task('Forms C and D', f'{P("People", "Owner forms")}. Owners upload the scans signed in front of witnesses.')
    g.steps([
        'Each row shows the owner, the form, the witnesses and when it was uploaded.',
        'Press Open to read the scan.',
        f'Press {B("Approve")}, or {B("Send back")} with What to fix (the owner reads this).',
    ], shot=S('admin/22-owner-forms-desktop', 0, 0, 1440, 470, pins=[(1, 420, 246), (2, 829, 246), (3, 1105, 246)]))

    # ---------------------------------------------------------------- 7
    g.chapter('Owner money',
              'Owner fee invoices are issued on the notice day and debited on the 15th. Statements are built, approved '
              'and issued each month, and payouts follow.',
              blurb='Owner invoices, the automatic debit, statements, payouts and the company statement.')
    g.task('Owner invoices', f'{P("Money", "Owner invoices")}')
    g.steps([
        f'{B("Run the monthly invoices")} issues the invoices for the 15th by hand, for a missed month. An invoice is never issued twice.',
        f'{B("Issue all tracker invoices")} bills the Tracker Install for each car waiting for its tracker.',
        'Filter by Open, Paid, Failed or In arrears. Failed invoices show the reason.',
        f'Paid by e-Transfer, cheque, cash or bank transfer? Press {B("Record payment")} under the invoice. Leave Amount empty for the full balance.',
    ], shot=S('admin/14-owner-invoices-desktop', 0, 0, 1440, 1060, pins=[(1, 1200, 237), (2, 600, 378), (3, 418, 460), (4, 743, 894)]))

    g.task('The automatic debit', 'The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.')
    g.flow([('Notice day', 'The 5th: invoices issued, one notice per owner'),
            ('Debit day', 'The 15th from 6:00: one debit per invoice'),
            ('Results', 'Cleared: paid. Returned: $50 Late Fee once'),
            ('Retry', 'From the 18th: the second and last try'),
            ('Arrears', 'Returned again: a task and an email to you')])
    g.steps([
        'The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.',
        'How it runs explains the policy in words, read from Program settings.',
        f'Scheduled and processing lists each debit. {B("Pause")} holds one (a reason is needed).',
        f'Owners lists each mandate. Use {B("Pause")}, {B("Resume")} or {B("Send a notice now")}.',
    ], shot=S('admin/15-owner-debits-desktop', 0, 0, 1440, 920, pins=[(1, 314, 200), (2, 309, 327), (3, 1317, 694), (4, 1220, 871)]))
    g.steps([
        'Results: each debit, cleared or returned, with the bank\'s reason.',
        'Run log: each notice and debit run, with its counts.',
        'Notices sent: who was told what, for which debit day.',
    ], shot=S('admin/15-owner-debits-desktop', 210, 940, 1440, 1460, pins=[(5, 345, 1015), (6, 335, 1212), (7, 400, 1407)]))
    g.warn('A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a '
           'task; nothing is debited for them. Change the days, retries and Late Fee under Debit settings (Program settings).')

    g.task('Owner statements', f'{P("Money", "Owner statements")}')
    g.steps([
        f'Press {B("Build all for a month")} (or {B("Build one")}).',
        f'Open each draft. Check it, {B("Rebuild")} after a correction, {B("Preview PDF")}, then {B("Approve")}.',
        f'Press {B("Issue to the owner")}. {B("Reissue")} sends a corrected copy; {B("CSV")} exports it.',
    ], shot=S('admin/16-statements-desktop', 0, 0, 1440, 400, pins=[(1, 1150, 109)]))
    g.figure(S('admin/17-statement-desktop', 0, 0, 1440, 520, pins=[(3, 1238, 118)]),
             note='An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.')

    g.task('Company statements', 'CarmaCars\' own monthly statement, in twelve sections.')
    g.steps([
        'Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.',
        'Switch between Total, Per owner and Per vehicle.',
        f'Download {B("PDF")}, {B("PDF by owner")} or {B("PDF by vehicle")}, or press {B("Email me the PDFs")}.',
        f'{B("Finalize")} freezes the month. {B("Rebuild")} works until then.',
    ], shot=S('admin/18-company-statements-desktop', 0, 0, 1440, 760, pins=[(1, 300, 213), (2, 279, 451), (3, 1110, 118), (4, 676, 118)]))

    # ---------------------------------------------------------------- 8
    g.chapter('Tolls and tickets',
              'Toll notices and tickets arrive by mail and email. Read them into the system, check each line against '
              'the notice, and the matching, charges and emails follow.',
              blurb='The work queue, reading a notice, checking its lines and charging the right person.')
    g.task('The work queue', f'{P("Recover", "Tolls and tickets")}')
    g.steps([
        'Filter the queue: Unmatched, Needs review, Matched not charged, Owner not billed, Staff, Charged not notified, Disputed.',
        'Each toll shows its notice, kind, issuer, plate, when, amount and who it was matched to.',
        f'Add one by one with {B("Log one")}, then {B("Save and match")}. {B("Import a CSV")} takes a statement file.',
    ], shot=S('admin/19-tolls-desktop', 0, 0, 1440, 500, pins=[(1, 455, 163), (2, 860, 260), (3, 1235, 109)]))

    g.task('Inside a toll')
    g.steps([
        f'Open a toll from the queue. Decide who pays: {B("Charge the renter")}, {B("Bill to the owner")} or {B("CarmaCars pays")}.',
        f'Wrong notice? Press {B("Dispute")}. Finance can also press {B("Match again")}.',
        'Reading profiles (top right on Read a notice) teach the reader an issuer\'s layout. Paste a notice\'s text under "Try it" to test one.',
    ])

    g.task('Read a notice')
    g.steps([
        f'Press {B("Read a notice")}. Choose the file: a PDF, a photo (JPEG or PNG) or a CSV, under 15 MB.',
        'Leave Reading profile on finding it from the text, or choose the issuer.',
        f'Press {B("Read it")}. The file is stored first, then read in your browser.',
        'Notices read lists every read with its status and counts.',
    ], shot=S('admin/20-tolls-read-desktop', 0, 0, 1440, 760, pins=[(1, 372, 313), (2, 520, 397), (3, 302, 451), (4, 372, 606)]))

    g.task('Check the lines and import')
    g.steps([
        f'The notice is on the left ({B("Zoom")}, {B("Open the file")}). The lines are on the right.',
        'Check each line beside the notice: kind, issuer, notice number, plate, date and time, amount, fees, due date.',
        f'Fix what was read wrong, then press {B("Checked against the notice")}. {B("Leave out")} skips a line; {B("Put it back")} returns it.',
        f'Press {B("Save as checked")}, then {B("Confirm and import")}.',
    ], shot=S('admin/21-tolls-review-desktop', 0, 0, 1440, 1150, pins=[(1, 613, 193), (2, 817, 504), (3, 1300, 700), (4, 1094, 437)]))
    g.tip('Renters matched with high confidence are charged at import, with the notice and the administration fee, when "Charge renters '
          'matched with high confidence now" is ticked. Other lines go to the work queue or stay as exceptions with the reason.')
    # ---------------------------------------------------------------- 9
    g.chapter('Settings',
              'Settings change the public site and the rules of the program at once. Program settings are kept '
              'as dated rows, so earlier values stay on record.',
              blurb='Site, program settings, official forms mapping, insurers and the other lists.')
    g.task('The Settings page')
    g.steps([
        f'Site setup lists what is still missing on the public site, with {B("Open site settings")}.',
        'Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.',
        'Program settings: every timing and policy value.',
        'Forms: the official ServiceOntario PDFs and what goes in each field.',
        'Insurers: insurance companies billed for bookings.',
    ], shot=S('admin/24-settings-desktop', 0, 0, 1440, 900, pins=[(1, 470, 297), (2, 372, 362), (3, 1115, 362), (4, 372, 659), (5, 372, 764)]))
    g.para('The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, '
           'Airports and delivery, Coverage prices, Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.')

    g.task('Program settings')
    g.steps([
        'Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.',
        'Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.',
        f'Change a value and press {B("Save")}. It is saved as a new row from today; the rows before stay as they were.',
    ], shot=S('admin/25-program-settings-desktop', 0, 0, 1440, 1000, pins=[(1, 372, 220), (2, 400, 490)]))

    g.task('Official ServiceOntario forms', 'Until a form\'s official PDF is mapped, owners get a data sheet with the values.')
    g.steps([
        f'Open {P("Settings", "Forms")}. Each form shows "Data sheet in use", "Mapping to check" or "Official PDF in use".',
        f'Press {B("Upload the official fillable PDF")}. Its fields are read in your browser.',
        'For each field, choose What goes in it (or "The owner signs here"), a Format, and Only when if it applies.',
        f'Press {B("Save the mapping")}, then {B("Download a filled preview")} for one car and check it.',
        f'Press {B("Checked: use for owners")}. Every owner\'s form of that kind is filled again, except ones already signed or filed.',
    ])

    g.task('Agreements to sign: investors and staff', 'Investment agreements and staff agreements are signed in the person\'s own portal, or on paper.')
    g.steps([
        f'Investor: open {P("People", "Investors")} and the investor. Under Investment agreement, press {B("Send a PDF to sign")}, choose the PDF and press {B("Send to sign")}.',
        f'Staff: open {P("Settings", "Staff and roles")}. Under Staff agreements, press {B("Send a PDF to sign")} beside the person.',
        'They get a notice and sign it in their portal by typing their name or drawing. The signed copy is filed with their documents.',
        f'Signed on paper instead? Press {B("Record paper signature")} in the same place and upload the scan.',
        f'Sent by mistake? Press {B("Withdraw")} and give the reason.',
    ])

    g.task('The user guides', f'{P("Settings", "Guides")}. The guide of each portal, as people read it under Guide.')
    g.steps([
        'Each guide shows its version, when it was published and whether there are unpublished changes.',
        f'Open a guide and press a section. Change its text and press {B("Show the preview")} to see it as people will. Press {B("Save the draft")}; each save is kept in the section\'s history.',
        f'Move a section with the arrows, hide it, or press {B("Add a chapter")}. Upload a screenshot under Screenshots and paste the line it gives you.',
        f'Press {B("Publish version")} (the next number). The portals show the new version at once.',
        'The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.',
    ])

    g.task('Insurers and the other lists')
    g.steps([
        'Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.',
        f'To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press {B("Add")}.',
        'Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.',
    ])

    # ---------------------------------------------------------------- 10
    g.chapter('Email, backups and site health',
              'Keep an eye on email use against the daily limit, the nightly backup and the occasional error page.',
              blurb='The email outbox and daily limit, suppressions, backups and Error 1102.')
    g.task('Email', f'{P("People", "Email")}')
    g.steps([
        'The banner shows today\'s emails against the daily limit. From 80, Admins get a notice; near the limit, digests and marketing wait first and booking and sign-in emails are held last.',
        'Filter the Outbox: All, Queued, Held, Sent, Failed, Suppressed or Skipped.',
        f'Open an email to {B("Resend")} or {B("Cancel")} it.',
        f'Suppressions: {B("Suppress an address")} stops all mail to it; {B("Lift")} undoes it.',
    ], shot=S('admin/23-email-desktop', 0, 0, 1440, 760, pins=[(1, 813, 241), (2, 511, 318), (3, 1180, 400), (4, 383, 174)]))

    g.task('Backups')
    g.bullets([
        'The database is backed up every night, encrypted, kept for 30 days and test-restored on the spot.',
        'Every Monday the newest backup is checked again: it must be under 30 hours old and restore cleanly.',
        'Nothing is emailed. A failed backup shows as a failed scheduled job under Alerts on Today. Tell your developer the same day.',
        'Keep a copy of the backup key in the company password manager. Without it no backup can be read.',
    ])

    g.task('When a page shows "Error 1102"')
    g.para('Our web host\'s free plan sometimes stops a page that takes too long. Reload the page; you are still signed in. '
           'Moving to the Workers Paid plan removes it.')

    g.reference(
        nav_rows=[('Today', 'Alerts and what needs you now'),
                  ('Requests', 'Answer requests with offers'),
                  ('Bookings', 'Overview, Money, Changes, History'),
                  ('Calendar', 'Every car; drag, block, unblock'),
                  ('Vehicles, Listings', 'Fleet and listing pipeline'),
                  ('Owner invoices, debits', 'Fees and the 15th debit'),
                  ('Owner statements', 'Build, approve, issue'),
                  ('Tolls and tickets', 'Read a notice, work queue'),
                  ('Portals and sign-in', 'Invite, password links, View as'),
                  ('Settings', 'Site, program, forms, insurers')],
        top_tasks=[('Send an offer', f'{P("Requests", "booking", "Send the offer")}'),
                   ('Change a booking', f'{P("Booking", "Changes", "Send to the renter")}'),
                   ('Publish a listing', f'{B("Cover the plate")}, then {B("Approve and publish")}'),
                   ('Let someone in', f'{P("Portals and sign-in", "Invite")}'),
                   ('Help someone sign in', f'{B("Send password link")}'),
                   ('See what they see', f'{B("Open as this person")}'),
                   ('Read a toll notice', f'{P("Tolls and tickets", "Read a notice")}'),
                   ('Monthly statements', f'{B("Build all for a month")}, Approve, Issue')],
        extra_problems=[('You can\'t change anything', 'You are viewing as someone. Press Exit on the red banner.'),
                        ('Asked for a 6-digit code', 'Open your authenticator app. Lost phone: remove the factor in the Supabase dashboard.')])
    return g
