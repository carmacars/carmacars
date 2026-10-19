from lib import Guide, S, B, P, U


def build():
    g = Guide(
        key='admin', title='Admin Portal Guide', short='Admin',
        promise='Run every booking, car, owner and dollar of CarmaCars from one place.',
        cover_shot=S('admin/01-today-phone', 0, 595, 390, 1350),
        audience='admins', signin_url='carmacars.ca/sign-in?next=/admin', lands_on='To do, the list of what needs you')

    g.start_page(
        who='The CarmaCars Admin: the owner of the business, signed in as rent@carmacars.ca. '
            'Admin sees and changes everything, and can open any other portal as one of its people. Staff work in the staff portal instead.',
        need=['The Admin email address: rent@carmacars.ca. Only that address can hold the Admin role (Admin > Settings > Admin access lists it)',
              'Access to that inbox (links work for 24 hours, once)',
              'A computer for most work. Admin also works on a phone, with the whole menu behind one Menu button'],
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
              'Admin opens on To do: what needs you now, most urgent first. The menu groups every screen into seven groups: '
              'Today, Bookings, Cars, Owners and partners, Money, People and Settings. Search finds any booking, car or person.',
              blurb='To do, the menu, search, keyboard shortcuts and your other portals.')
    g.task('To do', 'Start every shift here. Each line counts what is waiting and has one button to deal with it.')
    g.steps([
        'The list is in order of urgency: owner applications, booking requests, changes renters asked for, failed payments, agreements to countersign, tolls, listings, plates not checked, insurance, cars using sample photos, staff commissions to approve and to pay, prices typed by hand to review, and staff who say they sourced a website request.',
        'Press the button on a line to go straight to that work. A line with nothing waiting moves to the bottom, under "more with nothing waiting".',
        'Below the list: today\'s pickups (ready or not ready) and today\'s returns (due or late).',
        f'Press {B("Overview")} for the money, fleet and queue figures, the alerts and the team\'s sales for the month.',
    ], shot=S('admin/01-today-desktop', 0, 0, 1440, 900, pins=[(1, 325, 284), (2, 1300, 285), (3, 265, 812), (4, 1360, 200)]))
    g.task('The menu', 'The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.')
    g.table([
        ['Today', 'To do, Overview, Tasks'],
        ['Bookings', 'Requests, Bookings, Calendar, Add a rental, Damage, Incidents and claims, Reviews'],
        ['Cars', 'Vehicles, Listings, Similar cars, Retire or delete, Rates for many cars'],
        ['Owners and partners', 'Applications, Owners, Partners, Owner forms, Paid and signed'],
        ['Money', 'Owner invoices, Owner debits, Payments and refunds, Owner statements, Company statements, Payouts, Staff commissions, Tolls and tickets, Insurer invoices, Reconciliation, Expenses'],
        ['People', 'Renters, Staff, Investors, Portals and view as'],
        ['Settings', 'All settings, Site, Program, Forms, Guides, Emails, Email log, Sample photos, Audit log'],
    ], head=['Group', 'Pages'])
    g.figure(S('admin/31-menu-phone', 0, 595, 390, 1250, pins=[(1, 40, 740), (2, 300, 838), (3, 300, 880)]), note='On a phone: press Menu (1), then a group (2), then the page (3).')
    g.task('Search', 'The search box sits at the top of the menu, on every page.')
    g.steps([
        'Type a booking number (CC-1042), a plate, a VIN, or a name or email address.',
        f'Press {B("Search")} (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.',
    ], shot=S('admin/32-search-desktop', 0, 0, 1440, 420, pins=[(1, 107, 190), (2, 1368, 197)]))
    g.task('Keyboard shortcuts', 'Press g, then a letter. Press / to jump to the search box.')
    g.table([
        ['g t', 'To do', 'g v', 'Vehicles'],
        ['g r', 'Requests', 'g l', 'Listings'],
        ['g b', 'Bookings', 'g a', 'Applications'],
        ['g c', 'Calendar', 'g o', 'Owners'],
        ['g k', 'Tasks', 'g m', 'Payments and refunds'],
        ['g s', 'All settings', '/', 'Search'],
    ], head=['Keys', 'Opens', 'Keys', 'Opens'], cls='keys')

    # ---------------------------------------------------------------- 2
    g.chapter('People and access',
              'Let people in, help them back in when they are locked out, and see exactly what they see. '
              'Every step is recorded in the audit log.',
              blurb='Portals and sign-in, invitations, password links, View as, staff and scorecards.')
    g.task('Portals and sign-in', f'Open {P("People", "Portals and view as")}. Every portal has a card.')
    g.steps([
        f'Each card links to {B("Its sign-in page")}, the address to send that person.',
        'Choose a person in the list on the card.',
        f'Press {B("Open as this person")} to see that portal as they see it.',
    ], shot=S('admin/27-portals-desktop', 0, 0, 1440, 820, pins=[(1, 949, 248), (2, 836, 323), (3, 743, 374)]))

    g.task('Invite a person', 'Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.')
    g.steps([
        'Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.',
        'Fill in the Name and Email.',
        'For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.',
        f'Press {B("Invite")}. The link in the email works for 24 hours.',
    ], shot=S('admin/27-portals-desktop', 210, 880, 1440, 1240, pins=[(1, 441, 1027), (2, 825, 1027), (3, 441, 1120), (4, 330, 1196)]))
    g.tip('Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: '
          'Owners and partners > Owners and People > Investors also have a one-click invite for a record without a sign-in.')

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

    g.task('The audit log', f'{P("Settings", "Audit log")} shows who changed what, and when.')
    g.steps([
        'Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.',
        'Every View as is recorded (view_as_start), with the person viewed.',
        'Search by table, record id or value.',
    ], shot=S('admin/29-audit-desktop', 0, 0, 1440, 560, pins=[(1, 325, 174), (2, 562, 260), (3, 1290, 116)]))

    g.task('Staff and roles', f'{P("People", "Staff")} opens Staff and roles.')
    g.steps([
        f'Invite staff here too: Role, Name, Email, Main function and Also covers, then {B("Invite")}.',
        f'Each row has {B("Send password link")}, {B("View as (...)")} and Limits (how much they may approve or refund).',
        f'Press {B("End access")} to close their staff portal at once. {B("Restore")} undoes it.',
    ], shot=S('admin/26-staff-desktop', 0, 0, 1440, 780, pins=[(1, 300, 460), (2, 1360, 676), (3, 1199, 722)]))

    g.task('Admin access', f'{P("Settings", "All settings")}, then Admin access. Who may hold the Admin role.')
    g.steps([
        'The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site\'s nightly checks sign in with.',
        'Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.',
        'Change the list only if the business\'s Admin address changes.',
    ])

    g.task('Staff scorecards', 'See how each assistant is doing against the targets.')
    g.steps([
        f'On a staff member\'s row in Staff and roles, press {B("Scorecard")}.',
        'By week shows each measure (for example quote sent within 5 minutes) and the result for each week.',
        'A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.',
    ], shot=S('va-sales/05-scorecard-desktop', 210, 120, 1440, 470, pins=[(2, 470, 270)]))

    g.task('Sales by staff member', 'See each person\'s commissions, quotes, offers, rentals added, bookings confirmed and booked revenue.')
    g.steps([
        f'On a staff member\'s row in Staff and roles, press {B("Sales")}. Press {B("By week")} or {B("By month")}.',
        'The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.',
        'Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.',
        f'A deal credited to the wrong person, or marked sourced when it was not? Press {B("Reassign")} beside it, choose who, say whether they sourced the client, and write the reason.',
        f'{B("Commission rate")} gives this person their own flat rate (empty: the Program settings). {B("Reverse")} beside a commission stops it, for example for a household rental found later.',
        f'Staff enter their own home address (at their first sign-in, before they sign their agreement, or in their profile). It is needed before they add a rental or earn a commission, and spots a household rental. {B("Home address")} here changes it if it is wrong.',
        f'The whole team: {P("Today", "Overview")}, the Sales card at the bottom. Choose another month and press {B("Show")}.',
    ])
    g.table([
        ['Credited to', 'Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it.'],
        ['Conversion', 'Of the deals credited in the period, the share confirmed so far.'],
        ['Booked revenue', 'The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off.'],
    ], head=['Figure', 'How it is counted'])

    # ---------------------------------------------------------------- 3
    g.chapter('Requests, offers and bookings',
              'Every booking starts as a request. You check it, adjust it and send the offer. After that, the booking '
              'page holds the money, documents, changes and history.',
              blurb='Answer a request with an offer, run a booking, and propose a change.')
    g.task('The request queue', f'Open {P("Bookings", "Requests")}. The oldest waiting request is at the top.')
    g.steps([
        'Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.',
        'Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.',
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

    g.task('A booking', f'Open {P("Bookings", "Bookings")}, then a booking number. Or type the number in the search box.')
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
    g.task('Who a booking is credited to', 'Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.')
    g.steps([
        'A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.',
        f'To give it to someone else, press {B("Reassign")}, choose who (or Nobody), say whether they sourced the client and write the reason. The booking\'s history and the audit log keep it, and the deal stays in the same week and month.',
        'Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.',
        f'Someone said they sourced a website request? The credit line shows the claim: press {B("Credit them")} or {B("Not theirs")}, with a reason.',
        f'A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press {B("Mark reviewed")} once you have looked at it.',
    ])
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
    g.task('A car\'s own calendar', f'{P("Cars", "Vehicles")}, then the car, then its Calendar tab.')
    g.steps([
        'The Calendar tab shows only this car, with its bookings and blocks.',
        f'Turnaround between trips on this car shows the time used. Press {B("Change")} to give this car its own time.',
    ], shot=S('admin/07-vehicle-calendar-desktop', 0, 0, 1440, 560, pins=[(1, 606, 174), (2, 740, 228)]))

    # ---------------------------------------------------------------- calendar sync (0062)
    g.chapter('Calendar sync with Turo and other platforms',
              'A car rented on Turo, Getaround or another site must never be booked twice. Calendar sync works both ways '
              'through calendar links (iCal): their trips block the car here, and our bookings block it there.',
              blurb='Paste each platform\'s calendar link, paste ours into the platform, clashes, links that stop working.')
    g.task('Bring Turo\'s trips in', f'{P("Cars", "Calendar sync")}. Do this once for each car listed on another platform.')
    g.steps([
        'On Turo, open the car\'s calendar and its calendar sync (export) settings, and copy the calendar link (it ends in .ics). On Getaround or another site, look for "Export calendar" or "iCal".',
        f'On Calendar sync, find the car, open {B("Add a calendar link")}, choose the platform and paste the link. Press {B("Add the link")}.',
        'The link is read at once and then every 10 minutes. The card shows "Working", when it was read and the next trips it found.',
        'Each trip becomes an "External booking" block on the car, with the turnaround before and after it. The car cannot be requested, offered or booked here for those times, and the public calendar shows them as taken.',
        f'A trip that moves or is cancelled on the platform moves or frees the block at the next read. {B("Sync now")} reads the link at once.',
    ])
    g.task('Send our bookings to Turo')
    g.steps([
        'Each car has its own CarmaCars link under "This car\'s CarmaCars calendar": one for Turo, one for Getaround, one for any other platform. Each leaves out the trips that came from that platform, so nothing comes back twice.',
        f'Press {B("Copy")} next to "For Turo" and paste it into the car\'s calendar import on Turo. Do the same for each platform.',
        'The link shows only "Booked" for our bookings (with the turnaround) and our blocks. No names, numbers or prices.',
        f'If a link was shared by mistake, press {B("Make a new link")}. The old one stops working at once: paste the new one into every platform again.',
    ])
    g.task('Double bookings', 'If a trip on another platform overlaps a confirmed CarmaCars booking of the same car, we tell you at once.')
    g.bullets([
        'An urgent Fleet task "Double booking: <car> on Turo and CC-1042", a line on To do and an email to Fleet and the Admins.',
        'Calendar sync lists it at the top with both trips. Move, swap or cancel one of the two. The task closes by itself once they no longer overlap.',
        'An offer or a booking awaiting payment over a trip on another platform raises a task for customer service: its payment would be refused, so withdraw the offer or change the dates.',
    ])
    g.task('A link that stops working')
    g.para('A platform answers an error when a link is reset or removed. After 3 failed reads in a row (a Program setting) Fleet gets a task and an email, and To do shows "Calendar links not working". '
           'The trips already read stay on the calendar. Copy the link from the platform again, remove the old one and add the new one.')
    g.tip('A block from another platform can be removed from the calendar like any block; calendar sync will not put it back. '
          'In Program settings, "Calendar sync": on or off, how often links are read (10 minutes), failures before an alert, and whether our links include the turnaround.', label='Good to know')

    # ---------------------------------------------------------------- 5
    g.chapter('Fleet and listings',
              'Vehicles is the fleet. Listings is the pipeline that turns a car into a page on carmacars.ca: '
              'photos, copy, a duplicate check and a covered plate on every public photo.',
              blurb='Vehicles, the listing pipeline, similar cars and covering licence plates.')
    g.task('Vehicles', f'{P("Cars", "Vehicles")}')
    g.steps([
        'Filter by status and mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.',
        f'Search by plate, model or owner. {P("Cars", "Rates for many cars")} changes the rates of many cars at once.',
        'Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker.',
    ], shot=S('admin/08-vehicles-desktop', 0, 0, 1440, 900, pins=[(1, 267, 174), (2, 1203, 116), (3, 1060, 350)]))
    g.tip('The Tracker card on a car says "Coming soon": live location, the remote immobilize request and mileage from '
          'the tracker need the tracker company\'s connection first.', label='Coming soon')

    g.task('The listing pipeline', f'Open {P("Cars", "Listings")}. A draft waiting for review shows Needs review.')
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

    g.task('A listing without photos yet: sample photos', 'A car can be listed before its photos are taken. Until then the site shows a sample photo.')
    g.steps([
        'Submit the listing without photos. The listing copy is still written for you from the car\'s details.',
        'The car page and the car\'s card show a sample photo, captioned "Sample photo", so renters know it is not this car. Staff see "Using sample photos" on the car and in Listings.',
        'Publishing does not wait for a plate check: a sample photo has no plate.',
        'Add the real photos when they are taken. Once real photos are approved they replace the sample at once; nothing else to do.',
    ])
    g.task('Sample photos', f'{P("Settings", "Sample photos")}. The pictures a car shows until its real photos are in.')
    g.steps([
        'Every body type has a built-in picture (sedan, SUV, truck, van, coupe, hatchback, electric car).',
        f'Add your own: choose the Body type, and a Make and Model if the photo is of that exact model, pick the Photo, and press {B("Add the photo")}.',
        f'The most specific photo wins: make and model, then make and body type, then body type. {B("Turn off")} or {B("Delete")} a photo you no longer want.',
        'Cars using sample photos lists the cars still waiting for real photos. It is also a line on To do.',
    ], shot=S('admin/36-sample-photos-desktop', 0, 160, 1440, 900, pins=[(4, 386, 323)]))

    # ---------------------------------------------------------------- 5b
    g.chapter('Partners, company cars and rentals added by hand',
              'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. '
              'You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.',
              blurb='Add a car, partners, add a rental, retire or delete a car, sample cars and tolls with two rentals.')
    g.task('Add a car', f'{P("Cars", "Vehicles")}, then {B("Add a car")}. First choose who supplies it.')
    g.steps([
        B("A program owner's car") + ': choose the owner. The car starts its onboarding (terms, agreements, registry) as if the owner had applied.',
        f'{B("CarmaCars-owned (company fleet)")}: no owner. All of its revenue is CarmaCars\' and it shows in the company statement as company fleet.',
        B("A partner rental company's car") + ': choose the partner. Leave the commission empty to use the partner\'s, or type one for this car.',
        f'Type the VIN, the plate and the details, and the rates if you have them. Press {B("Add the car")}.',
    ])
    g.tip('The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.')
    g.para(f'On a car\'s page, {B("Who supplies the car")} shows the supplier and the commission, and changes them. Vehicles filters by supply type.')

    g.task('Partners', f'{P("Owners and partners", "Partners")}. Partner rental companies whose cars we rent out on commission.')
    g.steps([
        f'Press {B("Add a partner")}: business and legal name, contacts, HST number, commission and insurance with its expiry date.',
        'Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Tasks gets a reminder (Program settings sets how many days before).',
        f'Banking (Admins only): {B("Save the payout account")} for the account we pay the partner into. The account number is stored encrypted. Press {B("Verify")} once checked.',
        f'Portal: {B("Invite to the owner portal")} gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.',
        f'Signed on paper? Press {B("Print the partner agreement")}, then record the signed scan under Record a paper signature.',
    ])

    g.task('Add a rental by hand', f'{P("Bookings", "Add a rental")}. For phone, walk-in, Turo, partner and insurer bookings.')
    g.steps([
        'Choose the car and the dates. The check shows clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.',
        'Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.',
        'Check the price: the car\'s rates, extras, coverage and deposit. An Admin may set the price by hand; assistants use the rate sheet and the discounts allowed.',
        f'Choose Where it came from and how it is paid: {B("Paid another way")}, {B("Send a payment link")}, {B("Charge the saved card when the renter signs")} or {B("Unpaid: invoice later")}.',
        f'Press {B("Check the calendar and the price")}. Tick {B("Do not email the renter")} if they should not get the confirmation. Press {B("Add the rental")}.',
    ])
    g.tip('The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. '
          'With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. '
          f'On the booking, {B("Verified in person")} records a licence checked at the counter. A past rental is recorded as completed.')

    g.task('Retire or delete a car', f'{P("Cars", "Retire or delete")}, or the car\'s own page.')
    g.steps([
        f'{B("Retire this car")} takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. {B("Restore")} brings it back.',
        f'{B("Delete this car")} removes a car added by mistake, with its photos. Only a car with nothing tied to money (no booking, payment, statement, toll or damage). Type the plate or the name to confirm.',
        f'On the same page, {B("Delete all sample cars")} deletes every sample car that meets the rule at once. Type DELETE SAMPLE CARS to confirm; the ones kept show why.',
    ])

    g.task('Tolls when two rentals overlap')
    g.para('Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: '
           'the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.')

    # ---------------------------------------------------------------- 6
    g.chapter('Owners and onboarding',
              'Owners apply on the site with List your car. Every application waits for you in one place, Applications: '
              'approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.',
              blurb='Applications, an owner\'s page, paid and signed, and Forms C and D.')
    g.task('Applications', f'{P("Owners and partners", "Applications")}. Every owner application, newest first.')
    g.steps([
        'The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.',
        'Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.',
        'Open an application to decide.',
    ], shot=S('admin/33-applications-desktop', 0, 0, 1440, 640, pins=[(1, 530, 254), (2, 700, 340), (3, 285, 340)]))
    g.task('Decide on an application', 'One page holds everything: the owner, the car, the uploads, the four checks and the notes.')
    g.steps([
        'Check the driver\'s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.',
        f'Press {B("Approve")}. The owner becomes active, the car gets its terms from the standard grid, the first and last month\'s invoices are issued, and the owner gets an email to sign and pay in the owner portal.',
        f'Missing something? Press {B("Ask for something")}, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press {B("Send to the owner")}. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.',
        f'Not a fit? Press {B("Decline")}, write the Reason the owner reads, and press {B("Decline the application")}. The owner is emailed for each car.',
    ], shot=S('admin/34-application-desktop', 0, 160, 1440, 900, pins=[(1, 1050, 633), (2, 1064, 436), (3, 1220, 436), (4, 1050, 491)]))
    g.tip(f'Notes on the page are for staff only: {B("Add note")} keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.')
    g.task('Owners', f'{P("Owners and partners", "Owners")}. Every owner, with their cars and where onboarding stands.')
    g.steps([
        'Each owner shows their application, how many cars, and where onboarding stands.',
        f'{B("View as (owner portal)")} shows their portal. {B("Send password link")} helps them sign in.',
        f'Invite an owner on file: fill in Name and Email under Invite an owner, then press {B("Send invitation")}.',
    ], shot=S('admin/12-owners-desktop', 0, 0, 1440, 560, pins=[(1, 590, 240), (2, 539, 276), (3, 1114, 462)]))
    g.para('The owner signs everything at once in their portal (Check and sign: the agreements, schedules, Forms A and B and the official forms that are ready). '
           'The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer\'s standing authorization. '
           'A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.')
    g.task('An owner\'s page', 'Open an owner from Owners. The details are in the right-hand column.')
    g.steps([
        'Upfront invoices: issue the first and last month\'s insurance fee for each car whose terms are set.',
        'Owner: address, sign-in, agreements, and what is still missing for the registry forms.',
        'Statements and payouts for this owner.',
        'Forms C and D, with a link to the review queue.',
        f'Further down: {B("View as (owner portal)")}, {B("Send password link")} and {B("Send a sign-in link to the owner portal")}.',
    ], shot=S('admin/13-owner-desktop', 1010, 280, 1420, 1310, hdr=False, pins=[(1, 1111, 325), (2, 1076, 619), (3, 1139, 1034), (4, 1097, 1290)]))

    g.task('Paid and signed', f'{P("Owners and partners", "Paid and signed")}. What each owner still has to pay or sign, and how each item was done.')
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

    g.task('Forms C and D', f'{P("Owners and partners", "Owner forms")}. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.')
    g.steps([
        'Each row shows the owner, the form, the witnesses and when it was uploaded.',
        'Press Open to read the photo or scan. Check each marked spot is signed or initialled.',
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
    g.flow([('Notice day', 'Invoices issued, one notice per owner, 10 days before'),
            ('Debit day', 'The 15th from 6:00: one debit per invoice'),
            ('Cleared', 'The invoice is paid'),
            ('Returned, insufficient funds', 'The $50.00 Late Fee is added once; the same amount is tried again within 30 days'),
            ('Returned for another reason', 'No retry and no Late Fee: the debit pauses and you get a task')])
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
    g.para('Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner\'s next debit, and the original amount is tried again within 30 days, '
           'as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.')
    g.warn('Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner\'s debit pauses, '
           'the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. '
           'An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.')

    g.task('Owner statements', f'{P("Money", "Owner statements")}')
    g.steps([
        f'Press {B("Build all for a month")} (or {B("Build one")}).',
        f'Open each draft. Check it, {B("Rebuild")} after a correction, {B("Preview PDF")}, then {B("Approve")}.',
        f'Press {B("Issue to the owner")}. {B("Reissue")} sends a corrected copy; {B("CSV")} exports it.',
    ], shot=S('admin/16-statements-desktop', 0, 0, 1440, 400, pins=[(1, 1150, 109)]))
    g.figure(S('admin/17-statement-desktop', 0, 0, 1440, 520, pins=[(3, 1238, 118)]),
             note='An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.')

    g.task('Staff commissions', f'{P("Money", "Staff commissions")}. Nothing is paid automatically.')
    g.flow([('Not earned yet', 'The rental is ahead, or not paid in full'),
            ('Pending approval', 'Completed and paid in full; a Sales month once it has ended'),
            ('Approved', 'You approved it; the staff member is told'),
            ('Paid', 'You recorded the payment; the staff member is told'),
            ('Reversed', 'Cancelled, refunded or charged back; after payment it comes off the next payment')])
    g.steps([
        'By person shows each staff member\'s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.',
        f'Press {B("Approve")} on a person (everything that may be approved now) or on one commission.',
        f'Press {B("Record a payment")}: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.',
        f'{B("Prices to review")} lists prices typed by hand; {B("Sourcing claims")} lists staff who say they sourced a website request; {B("Payments made")} lists each payment.',
    ])
    g.table([
        ['Sales', 'By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month\'s rentals'],
        ['Customer service, finance, fleet, field staff', '10% (also the field referral fee)'],
        ['Base', 'The rental charge before tax, after discounts, less refunds'],
        ['On the owner statement', 'An owner\'s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner\'s car: from CarmaCars\' commission. A CarmaCars-owned car: a CarmaCars expense'],
    ], head=['', 'Commission'])
    g.tip('A commission that changes after an owner statement was built (a refund, or the month\'s Sales tier) goes on the owner\'s next statement as an adjustment line.')

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
    g.task('The work queue', f'{P("Money", "Tolls and tickets")}')
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
    # ---------------------------------------------------------------- live visitors and live chat (0060)
    g.chapter('Live visitors and live chat',
              'See who is on the site right now and what they look at, with buying signals, and answer the live chat. '
              'The CarmaCars assistant answers the chat first; you take over whenever you want, and it hands over by itself '
              'for complaints, damage, payments and anything it should not answer.',
              blurb='Who is on the site now, signals and follow-ups, interest per car, the chat inbox, take over and hand back.')
    g.task('Live visitors', 'Visitors who accepted analytics, known customers on their own booking pages and anyone in a chat.')
    g.steps([
        f'Open {P("Today", "Live visitors")}. The tiles count who is on the site now, known customers, visits and chats today.',
        'Each visitor shows their name when known (signed in, or arrived from one of our emails), otherwise "Visitor from Toronto, phone"; the page and car they are on; the pages and cars of this visit; their visit number, device, city and the site or campaign that sent them.',
        'Badges are buying signals: "Viewing spree: 6 cars in 10 minutes", "Opened offer CC-1042, not answered", "Opened the change proposal twice", "Left the pay page", "Returning visitor, 3rd visit this week", "Started a request and stopped".',
        f'Press {B("Pages")} for every page and event of the visit, or {B("Start a chat")} to write to the visitor. They see your message in a bubble and reply from it.',
        'Below: the signals of the last 24 hours and the most viewed cars of the week. The page refreshes by itself every few seconds.',
    ])
    g.task('Follow-up tasks', 'Signals of known visitors become tasks with a suggested action, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours".')
    g.bullets([
        'An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.',
        'The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.',
        'A booking request started and stopped, or a viewing spree, by a known visitor: Sales.',
        'A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.',
        f'The thresholds are in {P("Settings", "Program")}, group "Live visitors and live chat". Follow-ups done count in My sales.',
    ])
    g.task('Recovery emails', 'Known renters who stop before finishing get one polite reminder, and at most one more a day later.')
    g.bullets([
        'An offer opened and not answered: after 4 hours. The pay page left without paying: after an hour. A change proposal opened and not answered: after 4 hours.',
        'A booking request started and not sent: after 2 hours, and only to renters who agreed to hear from us (marketing consent).',
        'Sent only between 9:00 and 21:00 Toronto time, never to someone who unsubscribed, and never while a staff member is handling the renter (a task they took, a chat with a person, a message from staff).',
        'They stop as soon as the renter answers, pays or sends the request; a reminder still waiting is not sent. The delays and hours are in Program settings, "Booking recovery emails".',
    ])
    g.task('Interest in a car')
    g.para(f'{P("Cars", "Vehicles")}, a car, Overview: "Interest on the site" shows who is looking now, views today and in 7 days, '
           'conversion over 30 days (requests from the people who viewed it) and the last 14 days. The Vehicles list has "Most viewed cars this week".')
    g.task('A renter\'s visits', 'On a renter\'s page (People > Renters, the name) and on a booking\'s History tab, "On the site" lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.')
    g.task('Live chat')
    g.steps([
        f'Open {P("Bookings", "Live chat")}. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).',
        'Choose a conversation. Beside it you see the visitor\'s page, pages, signals, and the renter with their bookings when known.',
        f'Press {B("Take over")}: the assistant stops and the visitor reads that you joined. Writing a reply also takes over. Press {B("Send")} (or Enter).',
        f'{B("Hand back to the assistant")} lets it answer again. {B("Close")} ends the chat; if the visitor gave an email they get a copy. {B("Email the transcript")} sends it any time.',
        'Notify me: "Email me when a chat waits (while I am on shift)" and desktop alerts in this browser. You are on shift while Live chat or Live visitors is open.',
    ])
    g.tip('The assistant only repeats prices from our pricing (a quote or the car\'s rates), never offers discounts or promises a car, '
          'never talks about insurance and never names a provider. Each reply it was not allowed to send says so in the conversation. '
          'When nobody is on shift, the chat asks for the visitor\'s name, email or phone and raises a task. A booking from a chat you handled '
          'is credited only when you choose "I sourced this client" on the quote or offer.')
    g.task('The assistant\'s settings')
    g.para('In Program settings, "Live visitors and live chat": the chat on or off, the AI first or not, its model, the neurons it may use a day '
           '(6,000, about 10 chats; then chats wait for a person), the greeting on car pages after some seconds (off by default), '
           'how long chats and visits are kept (12 months and 90 days, as the privacy policy says).')

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
        'First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.',
        'Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month\'s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026.',
        f'Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press {B("Save the defaults")}.',
        'Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.',
        'Calendar sync, Booking recovery emails and Site check: how often calendar links are read, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca).',
        f'Change a value and press {B("Save")}. It is saved as a new row from today; the rows before stay as they were.',
    ], shot=S('admin/25-program-settings-desktop', 0, 0, 1440, 1000, pins=[(1, 372, 220), (2, 400, 490)]))

    g.task('Official ServiceOntario forms', 'The five official forms are loaded with a draft mapping to the owner, car, company and lender details. Until you check a form, owners get a data sheet with the values.')
    g.steps([
        f'Open {P("Settings", "Forms")}. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.',
        f'Press {B("Download a filled preview")} for one car and check each value against the form.',
        'Change a field if needed: What goes in it (or "The owner signs here"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.',
        f'Press {B("Checked: use for owners")}. Every owner\'s form of that kind is filled again, except ones already signed or filed, and owners sign it with their other documents.',
        f'A new version from ServiceOntario? Press {B("Upload the official fillable PDF")}: the fields of the same name keep their mapping.',
    ])
    g.tip('SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company\'s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner\'s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person.', label='Good to know')

    g.task('Agreements to sign: investors and staff', 'Investment agreements and staff agreements are made from the person\'s record and signed in their own portal, or on paper.')
    g.steps([
        f'Investor: open {P("People", "Investors")} and the investor. Under Investment agreement, press {B("Send the agreement to sign")}. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press {B("Send to sign")}.',
        f'Once the investor signs, the agreement shows {B("Awaiting countersignature")} on the investor\'s page and on To do. It is not countersigned automatically: check it and press {B("Countersign")}. CarmaCars is bound once it has countersigned and the funds clear.',
        f'Staff: open {P("People", "Staff")}. Under Staff agreements, press {B("Send the agreement to sign")} beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.',
        'A field staff member\'s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.',
        'They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.',
        f'Your own PDF instead? {B("Send a PDF to sign")} still works.',
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
    g.task('The guides keep up by themselves', 'After every update of the site that changes the portals, the guides are checked without anyone asking.')
    g.steps([
        'Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.',
        'The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal\'s own labels and menu, checked, and published. The PDFs of those guides are printed again.',
        f'Such a section says {B("Changed automatically on")} and the date, in the list of guides and in the guide\'s editor. Not right? Open the section and press {B("Revert")}: the text it replaced comes back, published at once.',
        'This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section\'s history. There is nothing to review.',
        'A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.',
    ])
    g.tip('The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.')

    g.task('Insurers and the other lists')
    g.steps([
        'Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes.',
        f'To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press {B("Add")}.',
        'Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.',
    ])

    # ---------------------------------------------------------------- 10
    g.chapter('Email, backups and site health',
              'Keep an eye on email use against the daily limit, the nightly backup and the occasional error page.',
              blurb='The email outbox and daily limit, suppressions, backups, the site check and its alerts, and Error 1102.')
    g.task('Email', f'{P("Settings", "Email log")}')
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
        'A failed backup, or none for 30 hours, opens a site alert: an email, a task and a line on To do. Tell your developer the same day.',
        'Keep a copy of the backup key in the company password manager. Without it no backup can be read.',
    ])

    g.task('Site health and alerts', f'{P("Today", "To do")}, the Site health card at the bottom.')
    g.steps([
        'Every 5 minutes the site checks itself: the home page, a car page, the sign-in page and the site\'s health check, and also emails, scheduled jobs, the nightly backup and Stripe payments.',
        'Each line shows Working, Problem or Not checked yet, what was found and how many checks failed in the last 24 hours.',
        'A page that fails 3 checks in a row (a single Error 1102 does not count) opens an alert: an email to rent@carmacars.ca, an urgent task and "Site problems found by the site check" first on To do. Emails failing, a failed job or backup, or a Stripe event that failed alert at once.',
        'When the check passes again you get one "Recovered" email and the task closes by itself. A new problem of the same kind within an hour shows on To do without another email.',
    ])
    g.tip('The address the alerts go to and the timings are in Program settings, "Site check".', label='Good to know')

    g.task('When a page shows "Error 1102"')
    g.para('Our web host\'s free plan sometimes stops a page that takes too long. Reload the page; you are still signed in. '
           'Moving to the Workers Paid plan removes it.')

    g.reference(
        nav_rows=[('To do', 'What needs you now, most urgent first'),
                  ('Search', 'Any booking, plate, VIN, name or email'),
                  ('Bookings', 'Requests, bookings, the calendar, adding a rental'),
                  ('Cars', 'Vehicles, listings, calendar sync, sample photos'),
                  ('Owners and partners', 'Applications, owners, partners, owner forms'),
                  ('Money', 'Owner invoices and debits, payments, statements, tolls'),
                  ('People', 'Renters, staff, investors, View as'),
                  ('Settings', 'Site, program, forms, guides, emails, audit log')],
        top_tasks=[('Answer an application', f'{P("Owners and partners", "Applications")}, then {B("Approve")}, {B("Ask for something")} or {B("Decline")}'),
                   ('Send an offer', f'{P("Bookings", "Requests")}, the booking, then {B("Send the offer")}'),
                   ('Change a booking', f'The booking\'s Changes tab, then {B("Send to the renter")}'),
                   ('Publish a listing', f'{B("Cover the plate")}, then {B("Approve and publish")}'),
                   ('Let someone in', f'{P("People", "Portals and view as")}, then {B("Invite")}'),
                   ('Help someone sign in', f'{B("Send password link")}'),
                   ('Read a toll notice', f'{P("Money", "Tolls and tickets")}, then {B("Read a notice")}'),
                   ('Monthly statements', f'{B("Build all for a month")}, Approve, Issue')],
        extra_problems=[('You can\'t change anything', 'You are viewing as someone. Press Exit on the red banner.'),
                        ('Asked for a 6-digit code', 'Open your authenticator app. Lost phone: remove the factor in the Supabase dashboard.')])
    return g
