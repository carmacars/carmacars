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
              'Admin opens on To do: the day\'s counts at the top, then what needs you now, most urgent first. The menu groups every screen into seven groups: '
              'Today, Bookings, Cars, People, Marketing, Money and Settings. The long groups come in labelled parts (for example People: Owners and partners, then Renters, staff and investors). Search finds any booking, car or person, and Ctrl+K jumps to any page.',
              blurb='To do, the menu, search, keyboard shortcuts and your other portals.')
    g.task('To do', 'Start every shift here. Each line says what to do and why, and its button opens a small pop-up that does it, already filled in. Nothing to remember and no menu to search.')
    g.steps([
        'Each piece of work is its own line (work of one kind for several cars is one line, such as Add real photos (72 cars); its button opens the list), marked Now, Today or When you can: a car the insurer has not confirmed, a car not on the site, a renter\'s documents to check, a visitor waiting in live chat, a booking request, a change a renter asked for, an owner application, an owner invoice waiting for payment, the first and last month an owner paid after their invoices were voided, the terms agreed with an owner still on the standard grid, documents an owner has not signed, an official form to check, a plate to check, a car showing sample photos, and any task of the Admin.',
        'Press the line\'s button: Mark insured, Set rates and publish, Review documents, Record payment, Record what they paid, Enter the terms, Record paper signature, Checked: use for owners, Open the chat, and so on. A line you do not need has Not needed or These are correct. The pop-up is filled in; check it and confirm. The line disappears once the work is done.',
        'Under the lines, the counts with one button each (failed payments, agreements to countersign, tolls, listings, insurance, staff commissions, prices typed by hand, sales claims, Turo emails). A count with nothing waiting moves to the bottom, under "more with nothing waiting".',
        'While no assistant holds customer service, sales, finance or fleet (the live verification\'s test accounts do not count), their tasks come to To do too, and so do their emails, to rent@carmacars.ca.',
        'Beside the list (under it on a phone): today\'s pickups (ready or not ready), today\'s returns (due or late) and today\'s chauffeur bookings, by time.',
        f'Press {B("Overview")} for the money, fleet and queue figures, the alerts and the team\'s sales for the month.',
        'The dark band at the top counts the day, each count one tap from its page: requests waiting (with how long the oldest has waited, red past the reply target), pickups and returns today, payments to chase, deposits to settle, staff tasks open and alerts. A count that needs you now is red and says so.',
    ], shot=S('admin/01-today-desktop', 0, 0, 1440, 900, pins=[(1, 330, 585), (2, 890, 590), (5, 1100, 505), (6, 1215, 222), (7, 840, 340)]))
    g.task('The menu', 'The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.')
    g.table([
        ['Today', 'To do, Overview, Staff tasks, Live visitors'],
        ['Bookings', 'Trips: Requests, Bookings, Calendar, Add a rental, Chauffeur. Customers: Live chat, Renter leads, Reviews. Problems: Damage, Incidents and claims'],
        ['Cars', 'Vehicles, Listings, Maintenance, Rates for many cars, Calendar sync, Similar cars, Retire or delete'],
        ['Money', 'Owners: Owner invoices, Owner debits, Owner statements, Payouts. Renters: Payments by day, Payments and refunds, Tolls and tickets. Company: Company statements, Reconciliation, Expenses, Insurer rates, Insurer invoices, Staff commissions, Field pay'],
        ['People', 'Owners and partners: Applications, Owners, Add a car for an owner, Partners, Owner forms, Paid and signed. Renters, staff and investors: Renters, Staff, Investors, Portals and view as'],
        ['Marketing', 'Ads: Listings, Posted ads, Social drafts. Results: Bookings by channel. Owners: Owner recruitment'],
        ['Settings', 'All settings. Website: Site, Vehicle pages, Sample photos, Add-ons, Discount games, Guides. Rules: Program, Forms, Maintenance, Emails. Records: Email log, Audit log'],
    ], head=['Group', 'Pages'])
    g.figure(S('admin/31-menu-phone', 0, 595, 390, 1250, pins=[(1, 40, 740), (2, 300, 838), (3, 300, 880)]), note='On a phone: press Menu (1), then a group (2), then the page (3).')
    g.task('Search', 'The search box sits at the top of the menu, on every page.')
    g.steps([
        'Type a booking number (CC-1042), a car code (CC-7F3A, on every car page and fleet card), a plate, a VIN, or a name or email address.',
        f'Press {B("Search")} (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.',
        f'To go to a page instead, press Ctrl+K (Cmd+K on a Mac) or {B("Jump to a page")} under the search box, type a few letters (Payouts, Program settings) and press Enter. The first line searches the records for what you typed.',
    ], shot=S('admin/32-search-desktop', 0, 0, 1440, 420, pins=[(1, 107, 190), (2, 1368, 197)]))
    g.task('Keyboard shortcuts', 'Press g, then a letter. Press / to jump to the search box, and Ctrl+K to jump to any page.')
    g.table([
        ['g t', 'To do', 'g v', 'Vehicles'],
        ['g r', 'Requests', 'g l', 'Listings'],
        ['g b', 'Bookings', 'g a', 'Applications'],
        ['g c', 'Calendar', 'g o', 'Owners'],
        ['g k', 'Staff tasks', 'g m', 'Payments and refunds'],
        ['g s', 'All settings', '/', 'Search'],
        ['Ctrl K', 'Jump to a page', 'Esc', 'Close it'],
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
          'People > Owners and People > Investors also have a one-click invite for a record without a sign-in.')

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
    g.task('Sales staff: in person or remote', 'Each Sales person works in person (Toronto) or remote (anywhere, a contractor). Staff and roles lists them under Sales staff: in person or remote.')
    g.steps([
        f'Press {B("Work mode")} on a person (or on their Sales page), choose In person or Remote and give the reason. A new Sales person starts in person.',
        'The list shows the mode, the rate now, the rate the month would end at, and for remote this month\'s touches against 400, the peak hours scheduled this week (20 needed, Thursday to Sunday afternoons) and the replies on time.',
        f'On a remote person\'s Sales page, Remote duties shows their checklist, touches, blocks and reply time. {B("Void")} beside a touch logged by mistake takes it off, with a reason.',
        'When you approve a Sales month, its mode, rates, touches and any drop are locked: a later change of mode or settings does not change it. Their My sales shows each month in one line.',
    ])
    g.table([
        ['Rates', 'In person 10%, 15% from 50 rental days, 20% from 100. Remote 5 points lower on every tier: 5%, 10%, 15%'],
        ['Credit', 'In person: walk-ins, handovers, partner visits and the rentals they source. Remote: only the rentals they source; a website request they answer with the first offer during their blocks is credited to them; a walk-in or a partner deal earns them nothing'],
        ['Remote minimum', '400 touches a month. Under it, when the month ends, the month\'s rate is one tier lower (5% becomes 2.5%). Settings > Program settings, Staff commissions, changes the minimum, the drop and the floor'],
    ], head=['', 'Rule'])

    # ---------------------------------------------------------------- 3
    g.chapter('Requests, offers and bookings',
              'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. '
              'You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking '
              'page holds the money, documents, changes and history.',
              blurb='Send an offer with or without a request, change it in place, take payments by part, run a booking, propose a change.')
    g.task('The request queue', f'Open {P("Bookings", "Requests")}. The oldest waiting request is at the top.')
    g.steps([
        'Filter by New, Waiting on the renter, Pushed back, Offer out, Signing and payment, or Offer expired.',
        'Waiting shows how long the renter has waited; red means past the first reply target (5 minutes, set in Program settings). Open a booking number to answer it.',
    ], shot=S('admin/02-requests-desktop', 0, 0, 1440, 820, pins=[(1, 560, 245), (2, 320, 355)]))
    g.tip('A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless '
          '"Email the renter when their request expires that way" is on in Program settings.', label='Good to know')

    g.task('Answer a request with an offer')
    g.steps([
        'The Review and offer tab shows the request as the renter sent it.',
        'Adjust the car, the dates, the rate type, the places, the rates and fees, the deposit and extras.',
        'Price on the right updates as you change things.',
        f'Add a message, choose how long the offer stays open, then press {B("Send the offer")}.',
    ], shot=S('admin/03-booking-review-desktop', 240, 527, 1440, 2077,
              pins=[(1, 300, 627), (2, 330, 1237), (3, 1130, 1187), (4, 1160, 2047)]))
    g.steps([
        f'Changed fields but not ready to send? Press {B("Save changes")}. The panel "The offer as the renter sees it" shows the result.',
        f'Can\'t do it? Press {B("Decline")} and fill in Reason and any alternative.',
        f'Need an answer first? Press {B("Ask the renter")} to send a question.',
    ], shot=S('admin/03-booking-review-desktop', 940, 97, 1440, 177, pins=[(6, 1146, 139), (7, 1030, 139)]), fig_w=5.0)
    g.para(f'Opening a request takes it for you: everyone else sees "Being answered by" your name and since when, with Send the offer and Decline off, until you send, decline or leave (20 minutes, renewed while you work; Program settings). Press {B("Take over")} to answer one someone else holds; it is noted in the history. A second answer is refused with who answered and when. A request from the website opens to Sales after 15 minutes (Program settings); until then Admins, customer service and fleet answer it.')
    g.task('Send an offer without a request', f'{P("Bookings", "Send an offer")}, or {B("Send an offer")} on Bookings and on Requests. For a customer on the phone, by text or at the counter: no request needed.')
    g.steps([
        f'The customer: type a name, phone or email and choose them. Not on file? Press {B("Add a new customer")}: full legal name, mobile, email (the offer link goes there) and date of birth. A customer already on file with the same email or phone is shown with Use: one person, one record.',
        'The car and the dates: type the car code, plate or name, or choose from the list; each car says Free or Not free for the dates. Then the pickup and return places (our location, delivery with the address and distance, airport).',
        'The price: the Rate sheet, A total for the whole rental, or A rate per day (times the days). A price typed by hand needs its reason. At the top of the price, Amounts I type: Before tax, or After tax (HST included) to type what the renter pays for each line, worked back to the amount before tax for you (a line without HST stays as typed; the choice is remembered on this device). Or type the Total the renter pays (after tax): the rental charge is worked out so the total comes to it exactly, the other lines kept. Set the kilometres, a promo code, the deposit, a discount and each fee (an Admin), and how damage is covered: with option 3 the Protection Plan price is the one the renter pays.',
        'How it is paid: the rental by card online (the usual way), e-Transfer, cash, cheque, bank transfer, platform payout or the insurer; the deposit by card hold, cash, e-Transfer or no deposit (an Admin).',
        'Who found this client, the message to the renter, how long the offer is open, and how the link goes: Email, Text, both or neither.',
        f'The right side is the offer as the renter will see it, priced by the database as you type. Press {B("Send the offer")}. {B("Save without sending")} keeps it as a request for later.',
    ])
    g.tip('It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. '
          'No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.', label='Good to know')

    g.task('Change an offer that is out', f'The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Press {B("Edit the offer")} on the booking.')
    g.steps([
        'Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed. Amounts I type (Before tax or After tax) and the Total the renter pays (after tax) work as on Send an offer.',
        'Write what changed in Message to the renter and choose how long the offer is open.',
        f'Press {B("Save and send the update")}: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press {B("Save without telling the renter")} and tell them yourself.',
        f'A confirmed booking is changed with {B("Change the booking")} (Propose a change, below).',
    ])
    g.tip(f'No need to withdraw first. {B("Withdraw the offer")} is only for taking it back for good; {B("Send again, later expiry")} gives the renter more time, '
          f'and {B("Renter approved by phone")} records a yes given on a call.')

    g.task('Edit a booking that has started', f'On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, {B("Edit the booking")}, {B("Edit")}.')
    g.steps([
        'Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking\'s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.',
        f'Type why, if you like, and tick {B("Email the renter what changed")}, or leave it off for a silent correction. Press {B("Save the changes")}.',
        f'What is open now shows at once: {B("Email a pay link")} or {B("Text a pay link")} for exactly that amount, {B("Charge")} the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.',
    ])
    g.tip('Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking\'s history. A closed booking\'s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.', label='Good to know')

    g.task('Fees, a forgotten fee and the balance', f'On the booking\'s Money tab, Fees lists each fee. Press {B("Change or add a fee")}.')
    g.steps([
        'Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.',
        f'Press {B("Save the fees")}. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.',
        'The renter sees the balance on their booking with a Pay button, and pays by card on Stripe\'s form.',
    ])
    g.tip('Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.', label='Good to know')

    g.task('Correct a renter\'s details', f'On the renter\'s page (People, Renters) or on any of their bookings, {B("Edit renter")}.')
    g.steps([
        'Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.',
        f'A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick {B("Email the renter a link to set a password")} to send one there. Unsigned agreements and offers go to the new address.',
        f'Press {B("Save the renter")}. An email that another renter has is refused with their name; the same phone is a warning.',
        f'The same person entered twice? Possible duplicates (same email, same phone, or same name and date of birth) shows under the renter. {B("Merge into this record")} moves the other record\'s bookings, licences, cards, payments, documents and messages here and fills any detail missing here; the other record stays, blocked, with the merge in both histories.',
    ])

    g.task('Payments by part: the rental, the deposit and later charges', 'On the booking\'s Money tab, Money by part shows what is still open for the rental, the fees and later charges, the deposit and the card on file. Each part is paid its own way, in any mix: for example the deposit in cash and the rental by card.')
    g.steps([
        f'{B("Record a payment")}: choose what it is for (the rental, fees, the deposit or a later charge) and how it was paid (e-Transfer, cash, cheque, bank transfer, platform payout, the insurer). An e-Transfer, cheque or transfer needs its reference. Press {B("Record it")}. The renter gets a receipt; {B("Print")} prints one to hand over.',
        f'{B("Collect a card")}: a payment (Everything open by default: the rental, the fees and any later charge in one), the deposit hold or saving the card. The renter types the card in Stripe\'s secure form: on this device ({B("Open the card form")}, then hand it over) or by a link texted or emailed to them ({B("Send the link")}). Staff never type a card number.',
        f'A deposit hold lasts about 7 days and shows the days left; while the car is out it is collected by itself before it lapses. After the return, settle the deposit (below). {B("Capture the hold")} for all of it keeps the money; a part capture or {B("Release the hold")} waits for the settlement while the car is out or something is open (an Admin may do it with the reason).',
        f'{B("Charge the saved card")} (Finance or an Admin): extra kilometres, fuel, damage or a late return, with the reason the renter\'s receipt shows. For a rental over 7 days, save the card and charge the deposit this way.',
        f'An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press {B("Confirm the booking")}).',
        f'A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press {B("Returned")} with the reference or receipt number.',
    ])
    g.tip('Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.', label='Good to know')

    g.task('Settle the deposit', f'The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking\'s Money tab, under Deposit, press {B("Settle the deposit")}. Issue the Check-in statement first.')
    g.steps([
        'The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.',
        'Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.',
        'Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.',
        f'Damage: {B("Keep the whole deposit (damage)")} turns what is left of the deposit into a damage charge, with what was damaged and the photos; the renter is told. {B("Bill damage")} adds a damage charge up to the $2,500 deductible (more goes through a claim): the deposit pays first, then the card on file.',
        f'Press {B("Settle")}. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.',
    ])
    g.tip('A card hold lapses after about 7 days. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.', label='Good to know')

    g.task('A booking', f'Open {P("Bookings", "Bookings")}, then a booking number. Or type the number in the search box.')
    g.steps([
        'Tabs: Overview, Money, Changes, History, and Drivers and documents.',
        'Overview shows the trip, the renter, what is still missing for the handover, and the price.',
        'Open tasks for this booking, with the queue and the due time.',
        f'Top right: {B("Stop blocking the calendar")}, {B("Cancel for the renter")} and {B("Cancel by CarmaCars")}.',
        'Under the booking number: where the booking is on its way, from Request to Closed, with the dates, the days, the total and who pays.',
    ], shot=S('admin/04-booking-desktop', 0, 0, 1440, 960, pins=[(2, 720, 447), (4, 1230, 139), (5, 330, 257)]))

    g.task('Check a car out or in', 'From the booking, with your phone or a tablet: the same checklist field staff use.')
    g.steps([
        f'A confirmed booking shows {B("Check out (pickup)")} under Check-out, check-in and signing; a booking on rent shows {B("Check in (return)")}. Today lists the check-outs and check-ins due, each with {B("Check out")} or {B("Check in")}.',
        'The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.',
        'Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.',
        f'A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press {B("See the photo report")}.',
    ])
    g.tip('Fleet, Sales and Customer service check cars out and in the same way from their own booking page.')

    g.task('The photo report, late returns and the return charges', f'Under Check-out, check-in and signing, press {B("Photo report")}.')
    g.steps([
        'The report shows the due-back time, the actual check-out and check-in, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.',
        'At check-in the late return (after the grace period of the fee defaults), the mileage overage and the fuel or recharging are written to the return charges at once. A gas car with no pump receipt is priced at the refill price per eighth (Program settings) plus the markup until the receipt is entered.',
        f'Not charging one? Press {B("Waive")} beside it and give the reason: it stays waived if the charges are worked out again.',
        f'The time was wrong? Press {B("Correct the check-in time")} (or the check-out time) with the reason: lateness and the late charges follow, and the history keeps both times.',
        'The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.',
    ])

    g.task('Signatures on the spot, or by link', 'The renter or an additional driver signs the rental agreement on your device, or on their own phone.')
    g.steps([
        f'While a signature is missing, the booking shows {B("Sign now on this device")}, {B("Email the signing link")} and {B("Text the signing link")}.',
        f'No agreement made yet (the renter has not saved their details at home)? {B("Sign now on this device")} still shows: press {B("Prepare the agreement to sign now")} and it is made on the spot.',
        f'{B("Sign now on this device")}: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press {B("Hand the device to")} and their name.',
        f'They read both agreements (CarmaCars\' and Blind Spot\'s), tick the statements and sign. Then {B("Back to the staff view")} for the next signer.',
        'The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy\'s signature record page.',
    ])

    g.task('Rental agreements: every version, every field', 'The booking\'s Rental agreements card: the current version of CarmaCars\' and Blind Spot\'s agreements, every earlier one, and what is still blank.')
    g.steps([
        'Once the agreement is signed and countersigned, any change to what it prints makes a new version of both documents by itself: the dates, the price lines, the car, a driver added or corrected, the coverage, the deposit or how it was paid, an address.',
        'A change to the dates, the price, the car, the drivers or the coverage option is signed again: the renter (and each driver it affects) gets their link by email and text, and the card shows "Agreement v3 waiting for signature". A correction (a typo in an address, a plate written differently) is filed without signing; the renter gets the corrected copy by email.',
        f'Check-out makes the "as picked up" copy (time out, km out, fuel out, the car\'s plate and VIN, the check-out report), countersigned by whoever checked the car out; check-in makes the closing copy (time in, km in, driven and charged, fuel in, late hours, damage, the return charges, the final totals). Both go to the renter by email.',
        f'{B("Every version")} lists each one with what changed and both PDFs. {B("Resend the signing links")}, or press the button with their first name beside it to have them sign on your phone or tablet.',
        f'The card lists what the agreements still print blank (a licence expiry, the insurer\'s policy number, the insured vehicle, a VIN). Type the values and press {B("Save the missing fields")}: the agreements follow.',
        f'Check-out stops while a field a claim needs is blank. An Admin can let it go ahead: type the reason and press {B("Override")}; the reason is in the booking\'s history.',
        f'{B("Make the agreements again")} checks both against the booking at once (they also follow every change by themselves).',
    ])
    g.task('Signing that holds up in a dispute', 'Every signature of a rental agreement, an amendment or a new version is made the same way, remotely or on your device.')
    g.steps([
        'The signer confirms it is them with a 6-digit code sent to their phone or email on file; the licence on file is shown.',
        'They say they read the documents, initial the key terms (damage and the deductible, the deposit and later charges, fuel, kilometres and late returns, their coverage, cancellation), give three consents (to sign electronically, to receive records electronically, to card charges under the agreement) and draw their signature.',
        f'Each step is recorded with its time, IP address and device, and the place when the device shares it. The signed PDFs end with a certificate of completion; anyone can check a signed file at {U("carmacars.ca/verify")}.',
        f'Typed names are off. For a signer who cannot draw, an Admin can turn on the accessibility fallback: {P("Settings", "Program")}, Esign typed fallback.',
    ])
    g.task('Card disputes: the evidence pack', 'Everything that proves the rental, in one PDF for Stripe.')
    g.steps([
        'When a card payment is disputed, the evidence pack is built by itself: the signed agreements with their certificates, the check-out and check-in reports with photos, kilometres and fuel, the licence, the payments and charges, every message to the renter, and the card checks from Stripe. It is staged in Stripe as the dispute\'s evidence, and To do gets an urgent task.',
        f'Open the booking: the Rental agreements card shows the pack. Press {B("Download")} to check it, then {B("Submit to Stripe")} before the evidence date.',
        f'{B("Build the dispute evidence pack")} makes one at any time (an Admin or Finance).',
    ])

    g.task('The licence before an offer is accepted', 'Front, back and a selfie, from the request on.')
    g.steps([
        'After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.',
        'The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.',
        f'Review the images as usual with {B("Review documents")}: the card Renter documents is on Review and offer too.',
        f'The switch is in {P("Settings", "Program")}, Booking requests and offers: Booking licence required (on), with the selfie (on).',
    ])

    g.task('Renter documents: licence and proof of coverage', 'A renter\'s licence photos, selfie and proof of coverage (OPCF 27 or a credit card\'s rental coverage) are checked before the handover. You check them yourself; no task is needed.')
    g.steps([
        f'A booking with documents waiting is a line on To do: "Check <renter>\'s documents for booking <number>", marked Now when the pickup is within two days. Press {B("Review documents")}.',
        'The pop-up shows each driver\'s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.',
        f'What to check is written once at the top. One wrong? Open {B("Reject this one")} under it, type the reason the renter reads and press {B("Reject")}: they are asked for a new one.',
        f'Then press {B("Approve all")}: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. Anything the system refuses is named with the reason.',
        f'The same pop-up is on the booking: the card Renter documents ({B("Review documents")}) on Overview and on Drivers and documents.',
    ])
    g.tip('Each opening of a renter\'s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-out (photos and four checks): the history says "checked in person". Field staff also review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from My jobs, with the same Approve all or a reason to reject: the history says the reviewer\'s role, field. Sales review the licence images (not the coverage) of any booking being arranged or under way from their To do or the booking, with the same Approve all or a reason to reject: the history says the role, sales.')

    g.task('Payments by day', f'{P("Money", "Payments by day")}: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.')
    g.steps([
        f'Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press {B("Show")}.',
        'Totals by method and for each day; cards read as the card and its last four digits, never a code.',
        f'The cash drawer: expected (cash in less cash given back) against the count Finance records with {B("Record the count")}; a difference shows over or short.',
        f'Refunds waiting: every refund asked for anywhere with the policy maths. {B("Approve")} or {B("Decline")} with the reason in the row, then {B("Issue the refund")}.',
        f'{B("Export CSV")} for the bookkeeper.',
    ])

    g.task('Propose a change to a confirmed booking', 'The renter gets an email and answers on their booking. The calendar moves only when they accept.')
    g.steps([
        'Open the booking\'s Changes tab. Under Propose a change, set the new pickup, return or car.',
        'To price it by hand, type a New rental charge before tax. Leave it empty to use the car\'s rates.',
        'Write the Reason, for the renter. They read it.',
        f'Press {B("Preview the price")}, then {B("Send to the renter")}.',
    ], shot=S('admin/05-booking-changes-desktop', 240, 1557, 1440, 2077, pins=[(1, 450, 1732), (2, 350, 1817), (3, 700, 1927), (4, 395, 2035)]))
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

    g.task('Review requests', 'Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.')
    g.table([
        ['Mid-trip check-in', 'Rentals of 2 days or more, 24 hours after the pickup: "How is the car? Reply or call if anything is off." No review ask.'],
        ['Review request', '1 hour after the check-in. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google.'],
        ['Reminder', '24 hours after the request.'],
        ['Final follow-up', '7 days after the request. Nothing more after it.'],
    ], head=['Message', 'When'])
    g.steps([
        'The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.',
        f'{B("Ask for a review")} sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.',
        f'On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press {B("Send anyway")} to send it now.',
        f'{B("Mark reviewed")} stops the messages when the renter tells you they already reviewed.',
    ])
    g.para('The messages also stop by themselves when the renter presses "I already left a review", leaves a review on the site, unsubscribes, '
           f'or a Google review is matched to them. {P("Bookings", "Reviews")} has the numbers (requests sent, on hold, reviews detected, the average rating), '
           'the hold list and the Google reviews to match.')
    g.tip('The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees "Something wasn\'t right? Tell us directly".')

    g.task('What the owner sees, and owner deductions', 'Each booking on an owner\'s or partner\'s car shows the card What the owner sees at the top of its page.')
    g.steps([
        f'{B("Hide from the owner")} keeps the booking\'s revenue from the owner until the car is returned, or until the owner statement covering it is approved. The owner sees the booking as Booked with its dates, and the calendar still shows the car busy. Add a reason if you like: it is kept in the history.',
        f'{B("Show to the owner")} shows it now. Approving the statement shows every hidden booking on it by itself.',
        'Not shown to the owner is for a booking with no owner revenue (an insurance placeholder, a shareholder\'s or the owner\'s own use at no charge): the owner sees only that the car is unavailable for those dates. A booking with revenue cannot be set this way.',
        'Add a rental and Send an offer have What the owner sees. It starts from Settings > Program, Owners and fleet: Owners see a booking\'s revenue (right away by default).',
        f'On the Money tab, Owner deductions on this booking: {B("Add a booking expense")} (cleaning, repair, fuel, platform fee or other, the amount, the reason the owner reads, a receipt number) comes off before Owner Revenue.',
        f'{B("Set the Revenue Share for this booking")} applies within the car\'s signed terms. Above the terms only an Admin can, with Above the signed terms ticked and the reason. {B("Back to the car\'s terms")} undoes it.',
        'Add a rental has the same under The car\'s owner.',
    ])
    g.tip('The owner\'s statement always includes every booking at its true amounts and lists each deduction with its reason, so the payout is always right. Customer service and sales add deductions only while Program settings let them change fees.', label='Good to know')

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
    ], shot=S('admin/06-calendar-desktop', 0, 0, 1440, 1000, pins=[(1, 340, 200), (2, 690, 200), (3, 560, 314), (4, 900, 447)]))
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
    ], shot=S('admin/07-vehicle-calendar-desktop', 0, 0, 1440, 560, pins=[(1, 670, 199), (2, 722, 259)]))

    # ---------------------------------------------------------------- calendar sync (0062, 0063: Turo by email)
    g.chapter('Calendar sync with Turo and other platforms',
              'A car rented on Turo, Getaround or another site must never be booked twice. Turo has no calendar link, so '
              'Turo works by email: Turo\'s trip emails block the car here, and you block our bookings on Turo by hand. '
              'Getaround, Google Calendar and other sites work through calendar links (iCal), both ways.',
              blurb='Turo by email (set up once, cars found by themselves, "Which car is this?", the guest, Done on Turo), calendar links for other platforms, clashes.')
    g.task('Set up Turo by email (once)', 'Turo emails rent@carmacars.ca for every trip booked, changed, extended or cancelled. One Gmail filter forwards those emails to trips@in.carmacars.ca, and each one blocks the car here within a minute.')
    g.steps([
        'In Gmail (rent@carmacars.ca): Settings, See all settings, Forwarding and POP/IMAP. Press Add a forwarding address and type trips@in.carmacars.ca.',
        f'Gmail sends a confirmation code to that address. Open {P("Cars", "Calendar sync")}: the code shows under "Turo by email" (and To do shows "Gmail forwarding to confirm"). Type it in Gmail and press Verify. Leave forwarding itself off: only the filter forwards.',
        'In Gmail, in the search box, show the search options. From: turo.com. Press Create filter, tick Forward it to: trips@in.carmacars.ca, and press Create filter.',
        'Nothing to set up per car. Every active car (not the sample cars) is matched by itself: see the next task.',
    ])
    g.task('How Turo emails find their car (automatic)', 'Each Turo email is matched to one of our cars by itself. You never type a car\'s name on Turo.')
    g.bullets([
        'The reader looks at the Turo car number in the email\'s links and pictures, the VIN, the plate, the year, make and model (C-Class finds a C 300, Model3 a Model 3, 3 Series a 330i), trim and colour words, the trip already on a car, and whether a car is already busy at those dates.',
        'A clear winner is applied at once. When two cars are close (two black 2021 Jettas), the assistant picks between them only if the email tells them apart; otherwise the email waits as "Which car is this?".',
        'Every match teaches the car what Turo calls it (its Turo car number and the name in Turo\'s emails), so the next email for that car matches at once. Each car on Calendar sync shows what it learned; press Forget next to one that is wrong.',
        f'Rarely needed: {B("Type its name on Turo (optional)")} on a car whose Turo name the reader cannot place. The Turo car number there is optional too.',
    ])
    g.task('Turo trips on the calendar')
    g.steps([
        'A trip booked on Turo becomes an "External booking" block on the car, with the turnaround before and after it. The car cannot be requested, offered or booked here for those times.',
        'A changed or extended trip moves its block; a cancelled trip frees the car. An older email never undoes a newer one.',
        'Each car lists its Turo trips: the dates, the Turo trip number, the guest\'s name as Turo shows it and their phone when the email includes it (press Call). The car\'s calendar block shows them too. Press Cancelled if Turo cancelled a trip and its email did not come.',
        f'{B("Add a Turo trip")}: the trip start and end (Toronto time), and the Turo trip number if you have it. Use it for a trip whose email did not come.',
        'Only what the email says is kept: the car, the dates, the trip number, and the guest\'s name, phone and email when Turo shows them (a hidden or masked number is never taken). The email itself is never stored.',
        'Each guest gets one contact record (source Turo), so a Turo guest who calls our line or writes in Live chat is recognised by their phone. Contact them only about their trip: never add them to a marketing list or send promotions (Canada\'s anti-spam law and Turo\'s rules on taking guests off the platform). Nothing is sent to them by itself.',
    ])
    g.task('Which car is this? (Turo emails to check)', 'Only an email the reader cannot be sure about waits under "Turo emails to check", with a Fleet task and a line on To do.')
    g.steps([
        f'To do shows "Turo emails: which car is this?". Press {B("Choose the car")}, or {B("Which car is this?")} on the email in Calendar sync.',
        'The pop-up shows what Turo calls the car and the trip, then our best guesses first (with colour and the plate\'s last 3). Press the right car. Not among them? Choose it under Another car and press This car.',
        'The trip is added and blocks the car, the task closes, and the car remembers what Turo called it: the next email for it matches by itself. Other emails waiting with the same Turo car number are matched at once.',
        f'Something else is missing (the dates or the trip number)? Check the trip on Turo, press {B("Add as a Turo trip")}, choose the car, check the dates and press {B("Add this trip")}. Not a trip (a request, a message)? Press {B("Dismiss")}.',
    ])
    g.task('Block our bookings on Turo (Done on Turo)', 'Turo cannot read our calendar. Each car on Turo lists, under "Block on Turo", the CarmaCars bookings not yet blocked there.')
    g.steps([
        'Open the car\'s calendar on Turo and block the dates shown (the turnaround is included).',
        f'Press {B("Done on Turo")}. The booking leaves the list.',
        'If the booking\'s dates change, it comes back with the old dates to free first. A booking cancelled here shows the dates to free on Turo: free them, then press Freed on Turo.',
    ])
    g.task('Getaround, Google Calendar and other calendar links', f'{P("Cars", "Calendar sync")}, for a platform that gives a calendar (iCal) link.')
    g.steps([
        f'Copy the car\'s calendar link on the platform (look for "Export calendar" or "iCal"). On Calendar sync, open {B("Add a calendar link")}, choose Getaround, Google Calendar or Other, paste the link and press {B("Add the link")}.',
        f'The link is read at once and then every 10 minutes; {B("Sync now")} reads it at once. Each trip becomes an "External booking" block with the turnaround.',
        f'Send our bookings there: press {B("Copy")} next to "For Getaround" (or "For Google Calendar", or "For any other platform") under "This car\'s CarmaCars calendar" and paste it into the platform\'s calendar import. It shows only "Booked" times: no names, numbers or prices.',
        f'If a link was shared by mistake, press {B("Make a new link")}. The old one stops working at once: paste the new one into every platform again.',
    ])
    g.task('Double bookings', 'If a trip on Turo or another platform overlaps a confirmed CarmaCars booking of the same car, we tell you at once.')
    g.bullets([
        'An urgent Fleet task "Double booking: <car> on Turo and CC-1042", a line on To do and an email to Fleet and the Admins.',
        'Calendar sync lists it at the top with both trips. Move, swap or cancel one of the two. The task closes by itself once they no longer overlap.',
        'An offer or a booking awaiting payment over a trip on another platform raises a task for customer service: its payment would be refused, so withdraw the offer or change the dates.',
    ])
    g.task('A link that stops working')
    g.para('A platform answers an error when a link is reset or removed. After 3 failed reads in a row (a Program setting) Fleet gets a task and an email, and To do shows "Calendar links not working". '
           'The trips already read stay on the calendar. Copy the link from the platform again, remove the old one and add the new one.')
    g.tip('A block from another platform can be removed from the calendar like any block; calendar sync will not put it back. '
          'In Program settings, "Calendar sync" and "Turo by email": on or off, how often links are read, the inbound address, the mailboxes allowed to forward (rent@carmacars.ca) and how long the email log is kept (90 days).', label='Good to know')

    # ---------------------------------------------------------------- 5
    g.chapter('Fleet and listings',
              'Vehicles is the fleet. Listings is the pipeline that turns a car into a page on carmacars.ca: '
              'photos, copy, a duplicate check and a covered plate on every public photo.',
              blurb='Vehicles, the listing pipeline, similar cars and covering licence plates.')
    g.task('Vehicles', f'{P("Cars", "Vehicles")}')
    g.steps([
        'Filter by status; More filters has who supplies the car, retired cars and the mode. Each row shows the plate, class, owner, mode, status, listing and daily rate.',
        f'Search by plate, model or owner. {P("Cars", "Rates for many cars")} changes the rates of many cars at once.',
        'Open a car for its tabs: Overview, Rates, Fees and coverage, Calendar, Listing, and Owner, documents, tracker.',
    ], shot=S('admin/08-vehicles-desktop', 0, 0, 1440, 900, pins=[(1, 1070, 280), (2, 540, 219), (3, 700, 472)]))

    g.task('Set a car\'s rates and kilometres', f'Open the car, then the {B("Rates")} tab. Everything on it saves together, in one step.')
    g.steps([
        'Type the four rates. Only the daily rate is needed: an empty weekend rate is the daily rate, an empty weekly rate is 6 days at the daily rate, and an empty monthly rate is 22 days.',
        f'Kilometres: keep {B("Use the defaults")} (the kilometres a day in Settings, Kilometre choices, and the extra kilometre rate in Fee defaults for the car\'s class), or choose {B("Custom for this car")} and type them.',
        'Check the deposit (the class default is filled in), and the delivery and pickup fees: each is one way, an empty pickup fee is the delivery fee, and 0 means not offered.',
        f'Read What renters pay under the fields: real prices for a weekend, a few weekdays, a week and a month, worked out the way bookings are priced. Press {B("Save the rates")}.',
    ])
    g.table([
        ['Daily rate', 'A price per day, for each day that starts on a Sunday, Monday, Tuesday, Wednesday or Thursday'],
        ['Weekend rate', 'A price per day, not for the whole weekend: each day that starts on a Friday or Saturday. Friday 10 am to Sunday 10 am is 2 days at this rate; Sunday to Monday is a daily day'],
        ['Weekly rate', 'The price for 7 days. Rentals of 7 to 29 days cost this for each 7 days, counted by the day. A 1 to 6 day rental never costs more'],
        ['Monthly rate', 'The price for 30 days. A 7 to 29 day rental never costs more'],
    ], head=['Rate', 'What it means'])
    g.tip('A problem shows on its own field, in words, as you type. When similar cars have rates, a line suggests them with Use these; it is only a hint. '
          f'The same fields are on {B("Add a car")}, so a car can be added with its rates in one pass.')
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
        f'Similar cars on file lists possible duplicates. Press {B("Not a duplicate")} or {B("Same car")}. An open flag does not keep the car off the site; only Same car does.',
        'The copy is written by itself from the car\'s facts and published when it passes the checks: nothing to type. To change a line, press Change; that field is then locked and kept by every new version.',
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
        f'A real car that is not on the site is a line on To do: press {B("Set rates and publish")}. The daily rate is filled in (the car\'s own, or the suggested rate from similar cars or the class); change it if you like and press {B("Publish now")}.',
        f'On the car itself, the Listing tab has {B("Publish now")}; each open item of its checklist has a button to where it is done.',
        f'From a listing review: press {B("Approve and publish")}, {B("Approve, publish later")}, or {B("Send back")} with what to fix.',
    ])
    g.warn('The plate check never holds a car back: a real photo whose plate is not checked stays private (the other photos, or the sample photos, '
           'show instead) and goes public by itself once its plate is covered or marked not visible. Listings already live show "Plate not checked" on such photos.')

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
        f'Cars using sample photos lists the cars still waiting for real photos. Each real car showing sample photos is also a line on To do, with {B("Add photos")}.',
    ], shot=S('admin/36-sample-photos-desktop', 0, 160, 1440, 900, pins=[(4, 386, 323)]))

    g.task('Publish now, and new cars published by themselves', 'Nothing between a new car and the site has to be finished first: the car goes on the site, and what is still open shows on its checklist.')
    g.steps([
        f'{P("Settings", "Program")}, {B("Publish new cars automatically")} (on by default): a new real car goes on the site by itself as soon as it has its year, make and model and its rates, when it is added with rates, when its rates are saved, when it is added for an owner, or when an owner\'s application is approved.',
        f'Otherwise open the car: its Listing tab says why it is not on the site and has {B("Publish now")}. A car with no rates yet is published with the suggested rates (similar cars, else the class defaults in Program settings); change them later on the Rates tab.',
        'Every real car has its listing from the moment it is added, as a draft. It shows in Listings and in Not on the site yet until it is published.',
        'An owner\'s own application waits for your decision before its car is published by itself; Publish now still works.',
        f'A car taken off the site by staff, or scheduled for a later date, is never published by itself: press {B("Publish now")}.',
    ])
    g.task('The checklist: what is still open on a listed car', 'Open items never stop publishing. They show as warnings on the car\'s Listing tab and after Publish now.')
    g.table([
        ['Paperwork', 'Ownership permit, registry forms, agreements signed, Forms C and D, upfront payment, registry visit, tracker, safety certificate'],
        ['Insurance', 'Not on the fleet insurance policy yet: the car can be booked, but not handed over'],
        ['Details', 'Colour, body, seats, gearbox: the car page leaves out what is missing'],
        ['Photos', 'No real photos: sample photos stand in. A photo whose plate is not checked stays private until it is'],
        ['No VIN yet', 'A car added by its plate alone: add the VIN when you have it'],
        ['Possible duplicate', 'An open flag in Similar cars. Only Same car keeps the car off the site'],
        ['Owner terms', 'The management fee (Revenue Share) and fees not set: a request uses the owner\'s terms or the standard grid'],
    ], head=['Item', 'What it means'])
    g.task('The fleet policy rule at handover', 'A program owner\'s car is listed and can be requested, offered and paid for while its paperwork is open. It is never handed over until the insurer confirms in writing that it is on the fleet insurance policy.')
    g.bullets([
        'Staff see a warning on a request and an offer for a car not on the policy yet.',
        'The handover refuses the car until the insurer\'s confirmation is recorded (Owners and onboarding). The field app says so on the job.',
        'Only real states keep a car off the site: retired, left the program, out of service, Turo only, bookings turned off, a self-managed owner in arrears, or a paused listing.',
    ])

    # ---------------------------------------------------------------- 5b
    g.chapter('Partners, company cars and rentals added by hand',
              'A car comes from one of three places: a program owner, CarmaCars itself, or a partner rental company. '
              'You add cars and rentals by hand, retire cars, and delete cars that were added by mistake.',
              blurb='Add a car, partners, add a rental, retire or delete a car, sample cars and tolls with two rentals.')
    g.task('Add a car', f'{P("Cars", "Vehicles")}, then {B("Add a car")}. Start with the VIN: everything else about the car comes from it.')
    g.steps([
        'Type or paste the VIN. At the 17th character the car is looked up: one line shows the year, make, model, trim, body, seats, doors, fuel, drive, gearbox and engine. Press Edit only if something is wrong.',
        f'When the VIN fits several trims, the form asks which trim it is: press the one on the car\'s papers or badge, or {B("Not sure")} (Admin > Today asks again).',
        f'No VIN at hand? Press {B("No VIN at hand? Add the car by its plate")} and choose the year, make and model from the lists. The VIN can be added later; the details fill in then.',
        'Tap the colour (it is not in the VIN). Leave it empty and it is read from the cover photo once the car has one.',
        'Check the class. It is set from the make, model, body and age (a 2016 Porsche Macan is Premium, an SUV is SUV) and the line under it says why. Change it if it is wrong.',
        'Choose who supplies it: ' + B("A program owner's car") + ' (choose the owner; the car starts its onboarding), ' + B("CarmaCars-owned (company fleet)") + ' (no owner; all of its revenue is CarmaCars\') or ' + B("A partner rental company's car") + ' (choose the partner; leave the commission empty to use the partner\'s).',
        f'The daily rate is filled in from similar cars, else the class. Keep it, change it, or empty it and set the rates later on the car\'s Rates tab. Press {B("Add the car")}.',
    ])
    g.tip('The title, description and features are written by themselves right after the car is added, from the VIN details. Change any of them on the car\'s listing; a field you change is kept.')
    g.tip('Every car gets a fleet number and its standard settings the moment it is added: a complete rate card (the daily rate you typed or the suggested one, '
          'weekend, weekly and monthly from it, the kilometres a day, the extra kilometre rate, the deposit and the delivery and pickup fee of its class) and drivers 18 to 20 allowed. '
          'Each value set this way says (Set automatically) on the car\'s Overview and Rates tab until you change it. The defaults come from Settings: Program and Fee defaults.', label='Good to know')
    g.tip('A VIN that does not add up (one character misread) shows a warning; you can still save it. A VIN the decoder cannot read asks only the year, make and model and never stops you: the details fill in when it is read later. The duplicate check runs as for every car: a VIN only once, a plate on one active car, and a likely twin waits for you in Similar cars before it is published.')
    g.para('The gearbox comes from the government\'s fuel economy data for the model when it has one gearbox for it, or from the VIN when the VIN states it. '
           'Seats come from the VIN, or the usual number for the body (4 for a coupe or convertible, 5 for a sedan, SUV or hatchback). '
           f'When either is not certain, Admin > Today shows {B("Confirm gearbox and seats")}: press the gearbox and the number of seats, then {B("Save")}. '
           f'A car whose VIN fits several trims shows {B("Pick the trim")} there: press the right one. Either way the title, description and search text are written again.')
    g.para(f'On a car\'s page, {B("Who supplies the car")} shows the supplier and the commission, and changes them. Vehicles filters by supply type.')

    g.task('Partners', f'{P("People", "Partners")}. Partner rental companies whose cars we rent out on commission.')
    g.steps([
        f'Press {B("Add a partner")}: business and legal name, contacts, HST number, commission and insurance with its expiry date.',
        'Open a partner for its cars, bookings, statements, payouts and documents. A warning shows when its insurance expires soon, and Staff tasks gets a reminder (Program settings sets how many days before).',
        f'Banking (Admins only): {B("Save the payout account")} for the account we pay the partner into. The account number is stored encrypted. Press {B("Verify")} once checked.',
        f'Portal: {B("Invite to the owner portal")} gives the partner the owner portal with its cars, bookings, statements and the partner agreement, filled in and signed on screen in three taps.',
        f'Signed on paper? Press {B("Print the partner agreement")}, then record the signed scan under Record a paper signature.',
    ])

    g.task('A partner fleet on its own rates', 'Some partners send a price sheet of their own rates instead of sharing what the renter pays. '
           '01 Motors works this way: its whole fleet is on the site, and staff manage its cars (it has no portal sign-in yet; add its email on the partner page and invite it later).')
    g.steps([
        f'{P("People", "Partners")} > the partner. {B("Pricing")} shows how it is paid: the renter pays the partner\'s sheet rate plus the markup (10% unless you set another), rounded to the nearest dollar; '
        f'CarmaCars keeps the markup plus its cut (20% of the sheet rate); the partner is owed the rest of its sheet rate. Press {B("Edit pricing")} to change the markup, the cut or the basis for every car at once.',
        f'{B("Cars")} lists each car with its sheet rates a day (1 to 2 days, 3 or more, 7 or more) and the renter\'s rates. Press {B("Edit")} on a car to change a negotiated rate, give that car its own markup or cut, '
        f'mark it {B("Insurance included")} or {B("No credit card needed")}, or confirm its model year. The renter\'s rates change at once.',
        'The site shows these cars with their tiers (1 to 2 days, 3 to 6 days, 7 days or more) and "Guideline rates; final price confirmed after review". A car with insurance included needs no coverage choice from the renter '
        '(coverage option 4, confirmed by itself); a car with no credit card needed takes a debit card for the payment and the deposit. The deposit, the licence and identity checks and the ages stay the same.',
        'The price sheet has no years, VINs or plates. Until you confirm the year, the site leaves it out and says "Year confirmed when you book"; an offer waits until the year is confirmed (Edit on the car, Model year). '
        'Add the plate and the VIN on the car\'s page before its first handover.',
        f'Real photos: open the car (its name in Cars), {B("Photos")}, and add them. Once approved they replace the eight studio stand-ins.',
    ])
    g.tip('The partner\'s monthly statement shows each rental at the sheet rate, the cut and the payout; never what the renter paid. A refund lowers the partner\'s share in proportion; a discount CarmaCars gives comes out of the markup.', label='Good to know')

    g.task("A partner's CRM (01 Motors' GoHighLevel)", f'{B("Settings")}, the {B("Partners")} tile, then the partner (or {B("CRM link")} on the partner\'s page). Their CRM gets our cars, kept up to date, and their cars come to us.')
    g.steps([
        f'Ask the partner for a Private Integration token and their location ID (the box {B("What 01 Motors gives us")} on the page says exactly what to create and which scopes to tick). Paste both and press {B("Connect")}. The token goes to the vault; the page only ever shows its last four characters.',
        f'Connect tests the link (their location, objects, products and pipelines) and runs the first sync. After that it runs by itself every 15 minutes, and within five minutes of a change to a car, a rate, a photo, a booking or a block. {B("Test connection")} and {B("Run sync now")} do it at once.',
        f'{B("What 01 Motors sees")}: CarmaCars\' own cars and program owners\' cars that are on the site, with rates, the next 60 days and photos, as records of a "CarmaCars Vehicles" object in their CRM (or as products when their plan has no custom objects). Partner cars are never sent: not theirs, not another partner\'s. Press {B("Change what we share")} to leave out program owners\' cars, rates, availability or photos.',
        f'{B("Partner price")}: the site\'s rates, or the site\'s rates less (or plus) a percentage, to the nearest dollar.',
        f'{B("Their cars coming in")}: name the object in their CRM that holds their cars (Test connection lists them), or their feed address. Each of their cars is matched to their car here, or added as their partner car (it waits off the site unless you choose otherwise), with their rates as its sheet rates, their booked dates as calendar blocks and their photos for a car with none. A car that waits shows {B("Add as their car")}, {B("Link")} or {B("Set aside")}.',
        f'{B("Leads both ways")} (off until you turn it on): requests for their cars, and requests that came through their booking links, become contacts and opportunities in the pipeline stage you choose; an opportunity they move to the stage you name becomes a lead in {B("Leads")}.',
        f'{B("Feed, widget and booking links")}: a JSON or CSV feed and a widget for their GoHighLevel funnels and sites (copy the iframe), and booking links carmacars.ca/p/01-motors/&lt;car&gt; that mark the request as theirs for 30 days. {B("New key")} ends the old feed and widget addresses at once.',
    ])
    g.tip('A link that has failed for an hour shows on Admin > Today. Disconnect deletes the token from the vault; what is already in their CRM stays there.', label='Good to know')

    g.task('Add a rental by hand', f'{P("Bookings", "Add a rental")}. For phone, walk-in, Turo, partner and insurer bookings, the owner using their own car, and placeholders: a rental already agreed. To send an offer instead, use Send an offer.')
    g.steps([
        f'Standing with the renter at pickup? Press {B("Start at pickup")}: type the renter\'s name and phone, choose the car, type the kilometres and the fuel, and press {B("Hold the car and finish later")}. The pickup is now; the car is held for 2 hours (renewed while you work on it) and you get a task to finish the rental.',
        f'Nothing is required to save: the form is saved as a draft as you type ({B("Save draft")} saves at once). Unfinished rentals, on Bookings and on this page, lists every draft with who started it, when, and what is still missing; Finish it opens it where it was left, on any device. Tick Hold the car while I finish to keep the car off the calendar while you type (2 hours, renewed as you save). Discard drops it and frees the car.',
        f'Quick start sets the usual choices in one tap: {B("Phone")}, {B("Walk-in")}, {B("Turo or another platform")}, {B("Insurance replacement")}, {B("Owner using own car")} or {B("Placeholder")}.',
        'Choose the car and the dates. The calendar and the price are checked by themselves: clashes with other bookings and the cleaning time after each trip. An Admin may book over a clash with a reason.',
        'The dates decide the case, shown under them (nothing to tick): a pickup ahead is an upcoming rental, handed over at pickup as usual. A pickup already passed with the return ahead is a rental already underway: it is recorded as on trip from the pickup you enter, on any active car (even one closed to public bookings), and anything a handover checks that is still missing (signature, licence check, coverage proof, deposit, condition report, insurance) becomes a task. A return already passed is a rental that has ended: kept as completed, paid another way or unpaid.',
        'Find the renter by name, email or phone, or add a new one: name, email, phone, date of birth and licence. Add any other drivers.',
        'We deliver it, or we pick it up: pick the address from the suggestions and its distance from our location prices the delivery (shown under the address), as on Send an offer.',
        'Check the price: every line of the price can be changed where it stands. Type a new amount in the line (the rental charge for the trip or a rate a day, the young driver fee, the Protection Plan, delivery, each add-on, the deposit, the kilometres a day); HST and the total follow. Add a line from the list or a charge of its own; Remove takes a fee off. The (i) beside each line says what it is and how it is worked out. One optional reason covers all the changes. At the top of the price, Amounts I type: Before tax, or After tax (HST included) to type what the renter paid for each line ("$270 after tax for the rental, $50 for the Protection Plan"): each is worked back to its amount before tax, and a line without HST stays as typed. The choice is remembered on this device. Or type the Total the renter pays (after tax): the rental charge is worked out so the total is exactly that, to the cent, and the line under it shows each line before tax. The total shown is the total that is saved; if they ever differ, it says by how much before you save.',
        'Any length: the dates may run past 30 days (up to the staff limit in Program settings, 730 days by default). From 30 days the rental charge is the monthly rate for each 30 days, and the monthly periods are listed. On the booking, Monthly periods shows each period: its share, and its own version of the agreement (CarmaCars\' and Blind Spot\'s), sent to the renter to sign a few days before it starts (Program settings: long_rental_agreement_lead_days, 3 by default), with what is due for it on the renter\'s Balance due. With Program settings, Charge the saved card for each period, on, that share is charged to the saved card when the agreement goes out (the renter gets the receipt; a declined or missing card gives Finance a task).',
        'A car whose listing is not finished (a draft listing, onboarding, no photos or no rates yet) can be rented at once: it shows Listing not finished in the car list and stays off the public site. With no rates yet, type the rental charge for the whole rental and the reason.',
        f'An owner\'s car that is not on the fleet insurance policy yet: only an Admin adds its rentals, and ticks I checked that this car is insured for this rental. An owner\'s car needs its terms (Revenue Share) first. The handover still needs the car on the fleet policy: press {B("Insurer confirmed")} once the insurer confirms it.',
        'Insurer billed later (or the Insurance replacement quick start): choose the insurer (Not listed: type its name, and it is added to the list), the claim number, the adjuster, the days and the daily rate authorized, the provisional end, and whether the insurer pays everything or the rental only. The booking is billed to the insurer; the renter owes only what it does not cover. The daily rate authorized is filled from the insurer\'s rate sheet for the car (Insurance replacements: rates and billing); a different rate needs the reason.',
        f'The rent is paid by: e-Transfer or cash (received), card on file (charged when the renter signs), payment link, platform payout (Turo), insurer billed later, cheque, bank transfer, or unpaid. Paid in parts (some cash, some e-Transfer): press {B("Add another payment (paid in parts)")} and type each amount. Then the deposit, its own way: card hold, cash, e-Transfer (with its reference and date) or no deposit.',
        'Before you save checks it all in one box: the renter, the car, the days, the total, what was received and what is still to collect, the deposit (or No deposit) and the agreement.',
        'The rental agreement: Send it to sign online, or Already signed on paper (a task asks for the scan). The calendar: untick Blocks the car\'s calendar for an insurance replacement with dates not known yet, with the reason.',
        f'Tick {B("Do not email the renter")} if they should not get the confirmation. Press {B("Add the rental")}.',
    ])
    g.tip('The rental is on the calendars at once (a payment link waits for the payment). The renter signs the rental agreement in their portal, or on paper and you record it. '
          'With the saved card, nothing is charged when you add the rental: the card is charged when the renter presses Accept and sign, and until then the rental is awaiting signature. '
          f'On the booking, {B("Verified in person")} records a licence checked at the counter. A rental already underway can be paid by payment link (the renter signs, then pays from their booking) or the saved card, like an upcoming one.')

    g.task('Retire or delete a car', f'{P("Cars", "Retire or delete")}, or the car\'s own page.')
    g.steps([
        f'{B("Retire this car")} takes the car off the site and the calendars and keeps every record. It needs no future confirmed booking. {B("Restore")} brings it back.',
        f'{B("Delete this car")} removes a car added by mistake, with its photos. Only a car with nothing tied to money (no confirmed or paid booking, payment, statement, toll or damage). Type the plate or the name to confirm.',
        'Booking requests that never confirmed and never took money (requested, offered, declined, expired) do not stop a delete. The confirmation lists them; they are removed with the car and a copy is kept. The renters stay on file.',
        f'On the same page, {B("Delete all sample cars")} deletes every sample car that meets the rule at once, with its requests. Type DELETE SAMPLE CARS to confirm; the ones kept show why, with the booking numbers.',
    ])

    g.task('Sample cars on the site', f'{P("Cars", "Vehicles")}, or {P("Settings", "Site")}. The 20 example cars the site started with, so the fleet never looks empty while the real cars are listed.')
    g.steps([
        f'{B("Hide sample cars")} asks first ("Hide all 20 sample cars from the site?"); press {B("Hide them")} to take every sample car off the site at once, or {B("Keep them")}. Nothing else stops it: not an enquiry, not an old request.',
        f'{B("Show sample cars")} puts the 20 back, with their photos and rates. Ones that were deleted are made again.',
        'On the site each one is marked "Example car". They never appear in search engines or the sitemap.',
        'A request on a sample car is never a booking. When the person picks dates, the car page and the request form show a real car free for them (the same make and model first, else the same class and body at a similar price) with one tap to switch to it. If they keep the sample car, it becomes an enquiry (number EQ-1001 and up) and customer service gets the task Suggest a similar real car, naming the free real car.',
    ])
    g.tip('Hide the sample cars once enough real cars are on the site. Delete all sample cars removes them for good.')

    g.task('Why a car is not on the site yet', f'{P("Cars", "Vehicles")}, the card Not on the site yet.')
    g.steps([
        'Every real car that is not on the site is listed with its next step first: the rates, Publish now, the listing review.',
        f'The same car is a line on To do with {B("Set rates and publish")}. The car comes off both once it is on the site.',
        'A car without photos is marked sample photos: once listed it shows a sample photo until its real photos are approved.',
    ])

    g.task('Tolls when two rentals overlap')
    g.para('Bookings held for an insurer and other placeholders are never matched to a toll. When two real rentals overlap the toll time, nobody is charged automatically: '
           'the toll waits in the work queue under Two rentals, with both bookings, and you choose who pays.')

    # ---------------------------------------------------------------- insurance replacements: rates and billing (0163)
    g.chapter('Insurance replacements: rates and billing',
              'Each insurance company pays an agreed rate a day for a replacement car, by car class. The rate sheet keeps those rates with their history; '
              'a rental billed to an insurer takes its rate from it, the insurer\'s invoice follows it, and each insurer\'s page shows what it was billed, paid and still owes.',
              blurb='The rate sheet by insurer and car class, the rate on a rental, the invoices and the billing history.')
    g.task('The rate sheet', f'Open {P("Money", "Insurer rates")}.')
    g.steps([
        'One row for each insurer, one column for each car class (the list in Settings > Vehicle classes). Each cell shows the rate today and, under it, a rate already saved for a later date. On a phone each insurer is a card with its classes.',
        f'Press {B("Set")} (or {B("Change")}) in a cell. Type the Daily rate and, when the insurer has them, a weekly cap, a cap for 30 days, a delivery and pickup allowance, the kilometres a day and a taxes note (printed on its invoices). Choose From, say why it changed, and press {B("Save the rate")}.',
        f'A change never overwrites the rate before it: it is a new rate from its date, and the earlier one stays in the history. {B("End")} stops a rate from a date.',
        'Add an insurer, or change its billing contact and email, in Settings > Insurers.',
    ])
    g.tip('A car takes the rate of its pricing class; when the insurer has no rate for that class, the rate of the car\'s other classes, in the order of the list. A 2024 Jetta (standard, also a sedan) replaced for an insurer that pays $65 a day for sedans is billed $65 a day.', label='Good to know')
    g.task('The rate on a rental')
    g.bullets([
        'Add a rental, Insurance replacement (or Insurer billed later): once the price is checked and the insurer chosen, the daily rate authorized is filled from its rate sheet for the car, with the caps and the taxes note under it.',
        'A different rate: type it, and Differs from the rate sheet asks for the reason. The rental is not added without it. Empty the field to take the sheet\'s rate again.',
        'The review screen of a request or an offer does the same when you choose Bill to and the insurer: the rate follows the insurer chosen, and a rate typed that differs needs the reason.',
        'An insurer with no rate for the car: type the rate the adjuster authorized, as before.',
        'The booking\'s Insurance replacement card (Overview and Money tabs) shows the insurer and the claim, the daily rate and where it comes from, Differs with the reason when it is not the sheet\'s, the caps, the days covered, what the insurer pays and its invoices.',
    ])
    g.task('Invoices to the insurer')
    g.bullets([
        f'{B("Draft insurer invoice")} on the booking bills the insurer at the booking\'s daily rate (the sheet\'s, or the one typed with its reason) for the days authorized.',
        'The weekly cap and the cap for 30 days lower the amount of a long rental. Billed for the rental only, the insurer also pays delivery and pickup up to its allowance; billed for everything, delivery and pickup above the allowance are the renter\'s.',
        'The invoice line says the rate and where it comes from (for example at $65.00 a day, Example Mutual rate sheet, Sedan), and the PDF prints the taxes note. Send it and record its payments in Money > Insurer invoices, as before.',
    ])
    g.task('Billing history', f'{P("Money", "Insurer rates")}, then the insurer\'s name.')
    g.steps([
        'The tiles: bookings, days used and authorized, billed, paid, outstanding, the average daily rate and the days the insurer takes to pay (from sent to paid).',
        'Rates by class (Set, Change and End work here too), then the History of the rates: each rate with its dates, its status, why it changed and who saved it.',
        'Billing by class: for each class the bookings, days authorized and used, billed, paid, outstanding, the average rate and the days to pay.',
        'Bookings: each booking with its class, claim, dates, days, rate (Sheet and the reason when it differs), what was billed, paid and outstanding, and its invoices (each opens its PDF).',
        f'Choose Picked up from and to and press {B("Show")} for a period. {B("Download CSV")} saves the bookings of the period for a spreadsheet.',
    ])

    g.chapter('Chauffeur service',
              'Visitors book a driver and a luxury car or van by the hour on carmacars.ca/chauffeur. The vehicles come from a partner\'s chauffeur price guide, each with a rate for 2 hours and a rate for 3 hours or more.',
              blurb='Chauffeur requests: quote, confirm and close them; the vehicles and their hourly rates.')
    g.flow([('Request', 'The visitor sends the date, hours and addresses'), ('Quote', 'You check with the partner and send the quote'),
            ('Confirm', 'The client agrees and pays'), ('Done', 'Mark it completed after the trip')])
    g.task('The requests', f'{P("Bookings", "Chauffeur")}. Each request has its number (CH-1001 and up), the vehicle, the date and start time, the hours, the pickup and drop-off addresses, the passengers, the occasion and the notes.')
    g.steps([
        f'The {B("Quote")} column is the price for the client: the hours at the 2-hour rate (exactly 2 hours) or the 3+ hour rate (3 hours or more), before HST, then HST and the total. The line under it is the quote line to send.',
        f'{B("Partner, CarmaCars")} shows the partner\'s sheet amount, what the partner is owed (the sheet amount less the cut) and what CarmaCars keeps (the markup plus the cut).',
        f'Check the vehicle and the driver with the partner for that time. To change the vehicle or the hours, press {B("Change")}: the quote is worked out again.',
        f'Send the quote line by email or phone, then press {B("Quoted")} and say how you sent it. The task in the queue is done.',
        f'When the client agrees, take the payment (a payment link, or at pickup), press {B("Confirm")} and note how it is paid.',
        f'After the trip press {B("Completed")}. {B("Decline")} or {B("Cancel")} closes a request with the reason.',
    ])
    g.tip(f'To do has a line {B("Chauffeur requests to quote")} while any request is new, and the card Chauffeur today lists the confirmed trips of the day.')
    g.task('The vehicles and their rates', f'{P("People", "Partners")} > the partner, card Chauffeur vehicles.')
    g.steps([
        'Each vehicle shows the partner\'s rates an hour and the client\'s (the markup added, rounded to the nearest dollar).',
        f'Press {B("Edit")} to change a rate, give it its own markup or cut, change the passengers, or take it off the site.',
        'A vehicle the partner also rents (chauffeur / rental) links to its car pages on the public page.',
    ])
    g.tip('Booking requests for cars, offers and payments do not cover chauffeur trips: a chauffeur request is a quote that you send and confirm here.', label='Good to know')

    # ---------------------------------------------------------------- 6
    g.chapter('Owners and onboarding',
              'Owners apply on the site with List your car. Every application waits for you in one place, Applications: '
              'approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.',
              blurb='Applications, the terms and first invoice, adding a car for an owner, an owner\'s terms and invoices, paid and signed, and Forms C and D.')
    g.task('Applications', f'{P("People", "Applications")}. Every owner application, newest first.')
    g.steps([
        'The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.',
        'Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.',
        'Open an application to decide.',
    ], shot=S('admin/33-applications-desktop', 0, 0, 1440, 640, pins=[(1, 530, 254), (2, 700, 340), (3, 285, 340)]))
    g.task('Decide on an application', 'One page holds everything: the owner, the car, the uploads, the four checks and the notes.')
    g.steps([
        'Check the driver\'s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.',
        f'Press {B("Approve")}. The step "Terms and first invoice" opens for each car, filled in with the owner\'s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent; with several cars, {B("Use these terms for every car")} copies the first car\'s numbers to the others.',
        'Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.',
        f'Press {B("Approve")} at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.',
        f'Missing something? Press {B("Ask for something")}, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press {B("Send to the owner")}. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.',
        f'Not a fit? Press {B("Decline")}, write the Reason the owner reads, and press {B("Decline the application")}. The owner is emailed for each car.',
    ], shot=S('admin/34-application-desktop', 0, 160, 1440, 900, pins=[(1, 1050, 633), (2, 1064, 436), (3, 1220, 436), (4, 1050, 491)]))
    g.para('The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says "Entered by staff" and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.')
    g.tip(f'Notes on the page are for staff only: {B("Add note")} keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.')
    g.task('Add a car for an owner', f'{P("People", "Add a car for an owner")}, or {B("Add another car")} on an owner\'s page. The owner never has to fill in the application.')
    g.steps([
        'The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.',
        'The car: type the VIN. The car is looked up at once and shown in one line (Edit if something is wrong); no VIN at hand, add it by its plate with the year, make and model from the lists. Tap the colour, check the class, then the odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender\'s information if you have them.',
        'Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner\'s terms, or their other car\'s; change them for this car.',
        'Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.',
        f'Press {B("Add the car and set it up")}. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.',
    ])
    g.para(f'Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, {B("Send the set-up email again")} sends the owner the email with a fresh link.')
    g.task('Owners', f'{P("People", "Owners")}. Every owner, with their cars and where onboarding stands.')
    g.steps([
        'Each owner shows their application, how many cars, and where onboarding stands.',
        f'{B("View as (owner portal)")} shows their portal. {B("Send password link")} helps them sign in.',
        f'Invite an owner on file: fill in Name and Email under Invite an owner, then press {B("Send invitation")}.',
    ], shot=S('admin/12-owners-desktop', 0, 0, 1440, 560, pins=[(1, 590, 240), (2, 539, 276), (3, 1114, 462)]))
    g.para('The owner signs everything at once in their portal (Check and sign: the agreements, schedules and Forms A and B; the official registry forms are printed and signed in ink). '
           'The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer\'s standing authorization. '
           'A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.')
    g.task('Mark a car insured (Insurer confirmed)', 'A program owner\'s car is handed over to a renter only once the insurer confirms in writing that it is on the fleet policy. Requests, offers and payment never wait for it.')
    g.steps([
        f'Each car waiting for the insurer is a line on To do: "Insurer has not confirmed <car>: mark it insured". It says Now when a booking picks the car up soon.',
        f'When the insurer\'s email arrives, press {B("Mark insured")}. The date is today; change it to the date of the insurer\'s email if it was earlier. Add its subject as the Reference if you like, and press {B("Insurer confirmed")}.',
        f'One email for several cars? Press {B("Mark several insured")} on the line "<n> cars wait for the insurer". Every waiting car is ticked: untick any car the insurer did not name, check the date, and confirm them all at once.',
        f'The same button is on the car: Overview ({B("Insurer confirmed")}) and the Listing tab\'s checklist, item "Not on the fleet insurance policy yet".',
    ])
    g.para('The car is then on the fleet policy from that date: it can be handed over, its Enrollment Date is that date, its fee terms start, and the owner gets the email "Written confirmation: your car is on the fleet policy". '
           'Its paperwork (agreements, registry visit, tracker) stays on its checklist until done. A car already listed and Available stays Available.')
    g.task('Owners who paid another way, and the terms you agreed', 'Two lines on To do keep an owner\'s money right without opening their page.')
    g.steps([
        f'"Record the first and last month paid by <owner>": their first and last month invoice was voided and nothing paid is recorded. Press {B("Record what they paid")}, type the amount for each car (tax included), or one total for several cars, how and when it was paid and the reference. A draft first and last month invoice is kept or voided, your choice. Each car\'s invoice is then marked paid, the owner gets the receipt and the two prepaid months count. Never for a shareholder.',
        f'"Enter the terms agreed with <owner>": their cars still use the standard grid. Press {B("Enter the terms")}: the Management fee (Revenue Share), the Insurance Fee, the Tracker Fee, the Install Fee and the first and last month are filled in from the grid. Type what you agreed for the owner, and open a car to give it its own. A car whose schedule is signed gets an updated schedule for the owner to sign.',
        f'Nothing to change? Press {B("Not needed")} or {B("These are correct")}: the line does not come back.',
    ])
    g.task('A shareholder\'s own car', f'On the owner\'s page, each car has {B("Shareholder\u2019s own car")}.')
    g.steps([
        'A shareholder\'s own car is split 90/10 (the share in Program settings) and pays no Insurance Fee, Tracker Fee, first and last month or tracker install.',
        f'Press {B("Shareholder\u2019s own car")}, say why (it is kept in the audit log) and confirm. Press it again to undo. Bookings already made keep their split.',
        'A first and last month or a tracker install invoice is refused for such a car, from any screen.',
    ])
    g.task('Cancellation refunds', f'{P("Settings", "Program")}: the refund for each cancellation tier.')
    g.table([
        ['Within 24 hours of booking, 48 hours or more before the start', '95%'],
        ['48 hours or more before the start', '75%'],
        ['24 to 48 hours before the start', '50%'],
        ['Under 24 hours, or after the start', '0%'],
    ], head=['When the renter cancels', 'Refund (default)'])
    g.task('An owner\'s page', f'Open an owner from Owners. Three tabs: Overview, Terms and Invoices. {B("Add another car")} and {B("New invoice")} sit under the name.')
    g.steps([
        f'Cars and terms, at the top: each car\'s Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and mode, with {B("Edit")} and History (see An owner\'s terms, car by car).',
        'Upfront invoices: issue the first and last month amount agreed on each car\'s terms, for each car whose terms are set.',
        'Owner: address, sign-in, agreements, and what is still missing for the registry forms.',
        'Statements and payouts for this owner.',
        'Forms C and D, with a link to the review queue.',
        f'Further down: {B("View as (owner portal)")}, {B("Send password link")} and {B("Send a sign-in link to the owner portal")}.',
    ], shot=S('admin/13-owner-desktop', 1010, 280, 1420, 1310, hdr=False, pins=[(1, 1111, 325), (2, 1076, 619), (3, 1139, 1034), (4, 1097, 1290)]))

    g.task('An owner\'s terms, car by car', 'The table Cars and terms, at the top of an owner\'s page and its Terms tab: each car\'s Insurance Fee and Tracker Fee a month, management fee (Revenue Share), Install Fee and Management Mode, and since when they apply.')
    g.steps([
        f'Press {B("Edit")} on a car\'s row. The row becomes fields: type the exact amounts (to the cent; the management fee in %). Before the Vehicle Schedule is signed you can also change the Install Fee, the Management Mode and the Onboarding Method.',
        f'Press {B("Review")}. It lists each value before and after, and what happens to each one. Nothing is saved yet.',
        f'Not signed yet (or not approved yet): {B("Save")} applies the numbers at once. An unsigned Vehicle Schedule is made again with them, so the owner signs these numbers; a car not approved yet keeps them for the Approve step.',
        'Signed: a lower amount is in force from today, or the date you choose under Lower amounts from. No notice period is needed because it only lowers what the owner pays. A lower management fee does this while Settings > Program, Lower management % without owner signature, is on (the default); off, the owner signs an updated Vehicle Schedule first.',
        'Signed: a higher Insurance Fee or Tracker Fee needs 30 days\' written notice (Enrollment Agreement 4.8). Choose the date under Higher amounts from (30 days ahead at the earliest) and write the Reason: the owner reads it.',
        'Signed: a higher management fee (Revenue Share) needs the same notice and the owner\'s signature. The owner is emailed the notice and an updated Vehicle Schedule to sign; it applies from the date once signed, or from the day they sign if that is later. Higher fees in the same change apply from the date by the notice either way.',
        f'Press {B("Confirm")}. The owner is emailed the written notice, which is also a PDF in their portal and in the car\'s History.',
    ])
    g.para('History, under each car, lists every period of terms (from, to, the amounts, and why: the Vehicle Schedule, a written notice, lowered) and every change with its notice. A change that has not started yet has Cancel (give the reason): the terms before it run on. An updated schedule waiting for the owner has Record signed on paper (with the date) and Withdraw it. One change at a time: cancel or finish the one waiting before making the next.')
    g.para('The same editor is on the car\'s page (Records tab, Owner terms). The owner\'s default terms (for cars whose terms are set later) and the first and last month invoice stay on the Terms tab.')
    g.tip('Invoices follow the dates: a month whose Insurance Fee or Tracker Fee changes part way is billed per day at each rate. The Revenue Share of a rental is the one in force on the day it is booked.', label='Good to know')
    g.task('Pay an owner a flat monthly amount', 'Some owners want the same amount every month for a car instead of a revenue share and fees. An Admin only, car by car.')
    g.steps([
        f'Open the owner\'s Cars and terms table (or the car\'s page) and press {B("Pay")} on the car\'s row.',
        f'Choose {B("Flat monthly payment")}, type the {B("Amount a month")} (for example 900.00), the date under {B("From")} and, if it ends, the {B("Last day")}. Write the Reason (kept in the history).',
        f'Press {B("Review")}: it says what happens and lists any monthly invoice already issued for those days. Then press {B("Confirm")}.',
        'From that date the owner\'s statement pays the amount every month (a part month by the day), with no revenue share and no Insurance Fee or Tracker Fee. Rentals ending on those days stay with CarmaCars, in the company figures.',
        f'Back to revenue share: press {B("Pay")}, choose Revenue share and the date. The flat period ends the day before; every period stays in the list.',
    ])
    g.tip('A month already on an approved owner statement never changes: a new date starts after it. A monthly invoice already issued for flat days stays: void or credit it. '
          f'A booking expense on a flat car is CarmaCars\' own unless you press {B("Charge to the owner")} beside it on the booking (an Admin only): it is then an owner cost on their statement. Owner costs recorded on the owner\'s account (tickets, tolls, damage of their own use) are charged as before.', label='Good to know')
    g.task('Change a signed car\'s Management Mode', 'Managed, Self-Managed or Turo-Only, from a date, for a car whose Vehicle Schedule is signed. An Admin only.')
    g.steps([
        f'Open the owner\'s Cars and terms table (or the car\'s page) and press {B("Change mode")} on the car\'s row.',
        f'Choose the {B("New Management Mode")} and its Onboarding Method (the options that fit how the car is held), the date under {B("From")}, and write the Reason: the owner reads it. Tick {B("The owner asked for this")} only when it is their own request.',
        f'Press {B("Review")}: it lists each value before and after (a Self-Managed car has no management fee; a Turo-Only car has no Fees and leaves the fleet insurance policy) and says whether the owner has to sign. Nothing is saved yet.',
        'The owner asked and no amount goes up: no signature and no notice period. From today (or the date you chose) the car has the new mode, an updated Vehicle Schedule is issued with CarmaCars\' signature and the owner is emailed the notice.',
        f'Anything else (CarmaCars\' own decision, or a higher fee): the owner is emailed the notice and an updated Vehicle Schedule to sign, the date is at least 30 days away and the car stays as it is until it is signed. In History, {B("Record signed on paper")} or {B("Withdraw it")}.',
        f'A change dated ahead applies by itself on its date: the schedule is issued and the car moves. {B("Cancel")} in History (give the reason) stops it and emails the owner that their terms stay as they are. The same email goes when a notice of a higher fee is cancelled.',
    ])
    g.tip('A shareholder-owned car has fixed terms. A car whose schedule is not signed yet changes its mode in the terms editor, where it applies at once.', label='Good to know')
    g.task('Paid and signed', f'{P("People", "Paid and signed")}. What each owner still has to pay or sign, and how each item was done.')
    g.steps([
        'Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.',
        f'Open {B("Checklist and quick actions")}. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.',
        f'Paid by e-Transfer, cheque, cash or bank transfer? Press {B("Record payment")}. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.',
        f'Signed on paper? Press {B("Record paper signature")}. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.',
        'The same checklist sits at the top of each owner\'s page.',
        f'You rarely need to come here: an upfront or overdue owner invoice is a line on To do with {B("Record payment")}, and an owner whose documents were sent two days ago or more and are not signed is a line with {B("Record paper signature")}. Both pop-ups are the same forms, filled in.',
    ])
    g.para('A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on <date>" in their portal. '
           'A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner\'s documents.')
    g.warn(f'Recorded the wrong thing, or a cheque bounced? Press {B("Void")} beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.')

    g.task('Forms C and D', f'{P("People", "Owner forms")}. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.')
    g.steps([
        'Each row shows the owner, the form, the witnesses and when it was uploaded.',
        'Press Open to read the photo or scan. Check each marked spot is signed or initialled.',
        f'Press {B("Approve")}, or {B("Send back")} with What to fix (the owner reads this).',
    ], shot=S('admin/22-owner-forms-desktop', 0, 0, 1440, 470, pins=[(1, 420, 246), (2, 829, 246), (3, 1105, 246)]))

    # ---------------------------------------------------------------- 7
    g.chapter('Owner money',
              'Owner fee invoices are issued on the notice day and debited on the 15th. Invoices of any amount are made by hand, '
              'as drafts first. Statements are built, approved and issued each month, and payouts follow.',
              blurb='Owner invoices (drafts, void and reissue, credit notes), the automatic debit, statements, payouts and the company statement.')
    g.task('Owner invoices', f'{P("Money", "Owner invoices")}. Every owner invoice, drafts and voids included. The same list is on each owner\'s and each application\'s Invoices tab.')
    g.steps([
        'Filter by Drafts, Open, Partly paid, Paid, Failed, In arrears or Void, or search by invoice number or owner. Open an invoice to see everything about it.',
        f'{B("New invoice")} makes an invoice of any amount for an owner\'s car, for example a registration fee of $123.45.',
        f'The monthly run and tracker invoices: {B("Run the monthly invoices")} issues the invoices for the 15th by hand, for a missed month (never twice); {B("Issue all tracker invoices")} bills the Tracker Install for each car waiting for its tracker.',
    ], shot=S('admin/14-owner-invoices-desktop', 0, 0, 1440, 1060, pins=[(1, 1200, 237), (2, 600, 378), (3, 418, 460)]))
    g.task('Make, edit and issue an invoice', 'A new invoice is a draft: the owner sees nothing and it is never debited until you issue it.')
    g.steps([
        f'Choose the car, a title (for example Registration fee) and, if you like, the due date (empty: 7 days after it is issued). Each line: the description, the quantity, the unit amount to the cent, HST on or off, and a note. {B("Add a line")} for more.',
        f'{B("Save as draft")} to come back to it, or {B("Save and issue")} to send it now. On a draft\'s page, {B("Issue and email")} sends it.',
        f'Paid another way? Press {B("Record payment")} on the invoice. The page lists the payments with their receipts, the automatic debits, the emails sent and the history.',
        f'{B("Resend email")} sends the invoice again. {B("PDF")} opens it as a PDF.',
    ])
    g.task('Correct an issued invoice', 'An issued invoice is never edited. You void it and issue a corrected one.')
    g.steps([
        f'Press {B("Void")}, write the reason (the owner reads it), keep Make a corrected invoice from it ticked, and press {B("Void the invoice")}. Its scheduled debit is cancelled and the owner is told.',
        f'The corrected invoice opens as a draft with the same lines. Fix the amounts and press {B("Save and issue")}.',
        f'Already paid? Void the payment first, or press {B("Credit note")} for the amount to give back: it gets its own number and the owner sees it.',
    ])
    g.para('Invoices issued before October 20, 2026 at the old default (for example $904.00, or $1,017.00 when the Insurance Fee was $450.00) are not changed by themselves. Where an owner agreed another amount, void them and reissue at the agreed amount.')

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
        ['Base', 'The rental charge before tax, after discounts, with late extra days; never delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off'],
        ['On the owner statement', 'An owner\'s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner\'s car: from CarmaCars\' commission. A CarmaCars-owned car: a CarmaCars expense'],
    ], head=['', 'Commission'])
    g.tip('A commission that changes after an owner statement was built (a refund, or the month\'s Sales tier) goes on the owner\'s next statement as an adjustment line.')

    g.task('Field pay', f'{P("Money", "Field pay")}. Field staff clock in and out on their phones (My hours); you run the pay every two weeks. Nothing is paid automatically.')
    g.flow([('Clocked in and out', 'Field staff press Clock in and Clock out; Fleet or you fix a forgotten clock-out'),
            ('Pay run started', 'Hours times the hourly rate, plus the approved commissions'),
            ('Approved', 'The figures are frozen, the period\'s hours are locked, the statements are numbered'),
            ('Paid', 'You recorded how each person was paid; they get their statement by email')])
    g.steps([
        f'The tab {B("Pay run")} shows the current two-week period (Sunday to Saturday: the first day is Settings > Program, Field pay). {B("Earlier period")} and {B("Later period")} move between periods.',
        f'After the period ends, press {B("Start the pay run")}: one line for each person with hours times their hourly rate, plus the staff commissions and referral fees approved by the end of the period (see Staff commissions). {B("Refresh the figures")} takes in a change made since.',
        f'Press {B("Approve")}. The period\'s hours are locked, each line gets a statement number and the figures are frozen. Someone still clocked in blocks it: fix their shift under {B("Hours")} first. {B("Withdraw")} takes an approved run back while no payment is recorded.',
        f'Press {B("Record payment")} on a line: choose e-Transfer, bank transfer or cash, the reference (not needed for cash) and the date. The commissions in the line are marked paid and the person gets their pay statement by email ({B("Send again")} repeats it). The statement\'s number opens its PDF; {B("CSV")} gives the run for your accountant.',
        f'{B("Hours")} lists everyone\'s shifts of the period. {B("Add hours")} enters a shift for someone who forgot to clock in, {B("Change")} fixes one and {B("Remove")} takes one out. Each needs a reason and is kept in a log. Fleet does the same under Field hours but sees no pay.',
        f'{B("Hourly rates")} shows each person\'s rate: CA$18.00 an hour unless you give them their own with {B("Set the rate")} (a reason is needed). A pay run keeps the rate it was started with.',
    ])
    g.table([
        ['Overtime', 'Off. Settings > Program, Field pay: pay overtime, after 44 hours in a week, at 150% of the rate'],
        ['Vacation pay', 'Off. Settings > Program, Field pay: vacation pay (Ontario: 4%) adds that share of wages, overtime and commissions to each statement'],
        ['Deductions', 'None are worked out: income tax, CPP, EI and the employer\'s contributions are for your accountant. Each statement says so'],
        ['Commissions that net to nothing', 'A person whose approved commissions add up to nothing or less (a clawback) is not paid them this period: they carry to the next'],
    ], head=['', 'Field pay'])
    g.tip('A shift of more than 16 hours (a setting) is refused, and so are hours that overlap another shift of the same person. The field staff member sees their hours and statements under My hours on their phone.')

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
              blurb='Who is on the site now, how likely each visitor is to book and why, one-click actions, follow-ups, interest per car, the chat inbox.')
    g.task('Live visitors', 'Visitors who accepted analytics (or got the notice in Canada outside Quebec and the US), known customers on their own booking pages and anyone in a chat.')
    g.steps([
        f'Open {P("Today", "Live visitors")}. "Live now" counts who is on the site now (seen in the last 5 minutes; an open page says it is still there every 45 seconds, so someone reading one page stays on the list). "Visitors today" counts people, with their visits below. The other tiles count hot visitors now, known customers now and chats today. The menu shows how many hot visitors are on the site.',
        'Visitors who chose necessary cookies only are never recorded: a line under the tiles says how many chose that today. Closing the tab takes a visitor off the list at once.',
        'Each visitor shows a booking likelihood from 0 to 100, with Hot (60 or more), Warm (30 or more) or Cold. The list is sorted by it; choose "Most recent" in Sort, or tick "Hot and warm only".',
        '"Why" gives the three strongest reasons, for example "Pickup tomorrow · Reached step 3 of the request form · Tapped to call". The badges are all the signals of the visit; the dots say how strong each is.',
        'Each visitor also shows their name when known (signed in, or arrived from one of our emails), otherwise "Visitor from Toronto, phone"; the page and car they are on, and how many others look at that car now; the device, city, the site or campaign that sent them and "from an ad".',
        f'Suggested: the best next step and the message to send. Press {B("Invite to chat with this message")} to send it at once, {B("Edit the message")} to change it first, {B("Offer a 10% discount code")}, {B("Assign to Sales")} or, when their dates are taken, {B("Suggest a similar free car")}.',
        f'Press {B("Pages")} for every page and event of the visit with each signal\'s points, or {B("Start a chat")} to write your own message. They see it in a bubble and reply from it.',
        'Below: hot visitors today (and whether someone acted), the signals of the last 24 hours, and the most viewed cars of the week with prices shown and the car most compared with each. The page refreshes by itself every 15 seconds.',
    ])
    g.task('The signals', 'Each signal adds points to the booking likelihood. They come from what the visitor does on the site, never from what they type.')
    g.bullets([
        'Intent: dates searched again and again, saw the full price, reached the booking form (and which step), came back for the same car on another day, comparing two or three cars, read the cancellation policy, read about the deposit, insurance or requirements, tapped to call, text or WhatsApp us or copied our number, checked delivery, looked through many photos or stayed long on one car.',
        'Urgency: pickup within 72 hours, weekend or holiday dates, on a phone late at night, came from a city or model page or a "near me" search.',
        'Value: a weekly or monthly rental, a premium car, SUV or van, adding a driver, asked about young drivers, a business email.',
        'Hesitation: watching the price (sorted by lowest price, lowered the price limit), left after seeing the price, unsure about the deposit, trouble with a form, the car not free for their dates.',
        'Context: came from an ad, a past renter, an offer or payment waiting, a game code not used yet, a popular car. The signals of known customers (offer opened, pay page left, change proposal, request stopped, returning visitor, viewing spree) count too.',
    ])
    g.task('Hot visitors and the actions')
    g.bullets([
        'When a visitor turns hot, everyone with Live visitors open sees an alert at the top of the page. Turn on desktop alerts in Live chat to get one on your computer too; none come in the quiet hours (11 pm to 7 am). No email is sent.',
        'A discount code is single use, 10% off the rental charge (at most $75), valid 3 days, one per visitor a week and 10 a day per person. Admins and Sales send them; the code goes in the chat with the message.',
        'Assign to Sales gives the visitor to the Sales person on shift (or to you if you work Sales) and raises a task with the reasons and the contact when we know who they are.',
        'Each action shows on the visitor ("Invited by Lena, 2 min ago") so two people do not write to the same visitor.',
    ])
    g.task('Signal settings')
    g.steps([
        f'Open {P("Today", "Live visitors")} and press {B("Signal settings")}.',
        'Score and actions: from how many points a visitor is hot or warm, when a signal is strong or medium, the hot alert, and the discount code (percent, most off a booking, days valid, codes a day per person, whether customer service may send codes, and the message).',
        'Each signal: on or off, its points, its thresholds (for example 72 hours for "Pickup soon", 3 searches for "Searching dates again and again"), the suggested action and the message. {car}, {days}, {pickup} and the other words in braces are filled in from the visit.',
        f'Press {B("Save the signals")}. The next look at each visit uses them.',
    ])
    g.task('Follow-up tasks', 'Signals of known visitors become tasks with a suggested action, for example "Call or message Maya Chen: opened offer CC-1042 twice, no answer for 6 hours".')
    g.bullets([
        'An offer opened and not answered: after 6 hours, to Sales when the booking is credited to someone in Sales, otherwise customer service.',
        'The pay page left without paying: after 30 minutes, customer service. The change proposal opened twice: customer service.',
        'A booking request started and stopped, or a viewing spree, by a known visitor: Sales.',
        'A task closes by itself when the renter answers the offer, pays or answers the proposal. Each signal raises one task only.',
        f'The thresholds are in {P("Settings", "Program")}, group "Live visitors and live chat", with how long "on the site now" lasts (5 minutes) and how often an open page says it is still there (45 seconds). Follow-ups done count in My sales.',
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
           'the people who saw the price for their dates, conversion over 30 days (requests from the people who viewed it), the cars most often compared with it, and the last 14 days. The Vehicles list has "Most viewed cars this week".')
    g.task('A renter\'s visits', 'On a renter\'s page (People > Renters, the name) and on a booking\'s History tab, "On the site" lists when they viewed the offer, opened the change proposal, viewed or left the pay page, which cars they looked at, and their chats.')
    g.task('Live chat')
    g.steps([
        f'A visitor who asks for a person is a line on To do, marked Now: press {B("Open the chat")}. Or open {P("Bookings", "Live chat")}. The menu counts chats waiting for a person. Open chats come first, those waiting for a person on top, with their minutes against the first reply target (5 minutes).',
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
           'how long chats and visits are kept, as the privacy policy says: chats 12 months, the pages of a visit 90 days, '
           'the visit\'s summary in Visitor history 13 months, and the daily totals, which name no one, 3 years.')
    g.task('What a visitor typed')
    g.para(f'A visitor who typed contact details into a form shows them on their line: "Typed into the booking request, not sent: Maya Chen, maya@example.com", '
           f'with {B("Email not confirmed")} until they open the link we emailed, and {B("Renter page")}.')

    # ---------------------------------------------------------------- the phone line (0085)
    g.chapter('Texts and calls (the Quo phone line)',
              'Every call and text on the CarmaCars number (Quo) is kept and matched to the person: staff, a renter and their booking, '
              'an owner or a lead. Staff answer texts from the same inbox as live chat. It is on by default; Program settings switch each part.',
              blurb='Texts and calls in the chat inbox, unknown callers, missed calls, booking texts, call summaries and the settings.')
    g.task('The inbox')
    g.steps([
        f'Open {P("Bookings", "Live chat")} and press {B("Texts and calls")}. Each number shows who it is (Renter, Owner, Lead, Staff or Unknown caller), unread texts and missed calls.',
        'Choose a number. Calls and texts are in order; a call shows its length, and Quo\'s summary or a one-line AI summary when there is one.',
        f'Write a text and press {B("Send text")}: it goes from the CarmaCars number through Quo. {B("Suggest a reply")} puts an AI draft in the box; nothing is ever sent until you press Send text.',
        'Beside the conversation: the renter with their bookings, the owner or the lead. A caller who gave the same phone in live chat or a discount game shows their visit on the site.',
        f'{B("Stop texts")} stops every text to the number, booking texts included. A person who texts STOP is stopped the same way; START allows texts again.',
    ])
    g.task('Unknown callers', f'Press {B("Unknown callers")}. For a number nobody on file has, type the name if you know it and press {B("Create lead")}, or find the renter and press {B("Link to")} the name. The calls and texts so far follow the link. {B("Match automatically again")} undoes a link made by hand.')
    g.task('Missed calls', 'A missed call raises the task "Missed call from ..." for the person on duty in customer service (whoever has Live chat or Texts and calls open), otherwise the customer service queue, and the Admins when nobody holds that function. In the quiet hours (11 pm to 7 am) the task is due at 7 am. One open task per number.')
    g.tip('Quo itself texts back missed callers (its own auto-reply). The platform can do it instead (Program settings, "Missed call: text the caller back"), once per number in 12 hours: turn off Quo\'s own auto-reply first, or callers get two texts.')
    g.task('Calls and texts on records', 'A booking\'s History tab, a renter\'s page and an owner\'s page have "Calls and texts": the texts, calls, missed calls, voicemails and summaries with that person. Calls are not recorded on the line for now, so there is no transcript or recording to show.')
    g.task('Booking texts', f'Since October 22, 2026 these are text alerts: each person chooses Email, Text or Both (the chapter Text alerts, below, and {P("Settings", "All settings")}, {B("Text alerts")}).')
    g.task('The settings')
    g.para('Program settings, "Phone and texts (Quo)": the line on or off, calls and texts kept, the missed-call text and its task, who calls back, AI suggestions and summaries with their daily neurons, '
           'the visit of a caller, and how long calls and texts of people who are not customers are kept (12 months).')

    # ---------------------------------------------------------------- text alerts (0096)
    g.chapter('Text alerts: email, text or both',
              'Every renter, owner, investor and staff member chooses how we reach them: Email, Text or Both. Texts go only to a phone they verified with a code, '
              'from the CarmaCars number, and each has a link to the page. It is on by default; nothing needs setting up.',
              blurb='Each person\'s channel, what is always emailed, STOP and START, quiet hours, US numbers, the texts and the daily count.')
    g.task('Who gets what')
    g.bullets([
        f'{B("Email")}: emails only. {B("Text")}: a short text instead of the email. {B("Both")}: a text and the email.',
        'Not chosen yet: Both for someone with a verified phone and an email, Text for an account made by phone without an email, otherwise Email.',
        'No verified phone, a number that replied STOP, a US number while US texting waits for A2P 10DLC, or a number outside Canada and the US: email only.',
        'Signed agreements, statements, receipts, invoices and notices are always emailed when there is an email address. Someone on Text also gets a text with a link to view or download it in their portal.',
        'Every customer email has its own short text: renters, owners, investors, additional drivers, co-signers and leads. Only the sign-in and security emails (password reset, sign-in link, security notice, "Continue your request") are never texts. A review request or a come-back offer is texted only when its email may go (marketing consent).',
        'An additional driver\'s or a co-signer\'s link is texted to that person (their own account with a verified phone), never to the renter or owner.',
    ])
    g.task('A person\'s channel', f'Open the renter, owner or investor under People. The card {B("How we reach them")} shows what they chose, what is used now and why, their verified phone, texts in the last 30 days and any STOP or START. Press {B("Change")} to set it (recorded in the audit log). Customer service and Sales can change a renter\'s or owner\'s; an investor\'s only Admins.')
    g.task('STOP, START and quiet hours')
    g.bullets([
        'A reply STOP (or OPT OUT, UNSUBSCRIBE, CANCEL, END, QUIT) stops texts to the number at once; texts waiting are not sent and their emails go instead. START turns texts back on. Every STOP and START is logged.',
        'Quo sends no confirmation, so we do: one text right away (quiet hours do not apply), "CarmaCars: you\'re unsubscribed and won\'t get more texts. Reply START to resubscribe." after STOP, and "CarmaCars: texts are back on. Reply STOP to opt out." after START. Once per change; the card How we reach them shows it as confirmed by text. A STOP or START you set by hand, or a carrier block, sends nothing.',
        'The first automated text to a number, and the first after START, ends "Reply STOP to opt out."',
        'Quiet hours, 9 pm to 8 am Toronto time: texts that are not urgent wait and go at 8 am. Urgent: late return notices, pickup and return details on the day, breakdown, accident and a disabled car.',
        'A text that is not sent after all (STOP, Quo refuses it, the person chose email meanwhile) sends the email it replaced.',
    ])
    g.task('The settings and the texts', f'{P("Settings", "All settings")}, {B("Text alerts")}: on or off, the defaults, the quiet hours, the STOP line, US numbers, and the text of each notification with a preview (edit, switch off, mark urgent). '
           'A text names CarmaCars, keeps {{link}}, has no long dash and is at most 320 characters; 160 is one text. The two confirmation texts (after STOP and START) are in the same settings. The generic text built from the email\'s subject is only for an email added later without its own text.')
    g.task('Texts a day', f'Site health on {B("To do")} has {B("Texts today")}: sent, notifications among them, failed, not sent and sign-in codes for the last 7 days, and the texts waiting for 8 am.')

    # ---------------------------------------------------------------- discount games (0066)
    g.chapter('Discount games and leads',
              'Visitors who are not signed in get one quick game: spin the wheel, scratch to reveal, quick blackjack, cup shuffle, Plinko, '
              'the card pack, coin flip, dice roll, slot machine, prize drop or mystery box. Every play wins a promo code or another go. '
              'To see the code they give a first name and an email (a mobile number is optional), so you get a lead. It is on by default; '
              'nothing needs setting up.',
              blurb='The giveaway game, the code it sends, game leads to call, and the report.')
    g.task('What the visitor sees')
    g.bullets([
        'On the 2nd page view (any page) or after 30 seconds on the site, whichever first, or (on a computer) when the mouse heads for the tabs. A card slides in at the bottom; on a phone it is a sheet at the bottom, never a full-screen block, and it always closes.',
        'Never for someone signed in, never on booking, pay, sign or sign-in pages, never on the first page of a visit from a search engine on a phone, never over the cookie banner; no new game for someone already known by email or with a booking request in progress. Closed, another game comes back on the 3rd page view after the close or 2 minutes later, at most 4 in a visit, and again on their next visit.',
        'After claiming a code: no game for the rest of that visit. A day after their latest claim the game comes back on their next visit with the usual timings, a new game and a new draw, and they can win another code. The day counts for the browser, the email, the mobile number and (in the request-to-book form) the account; within it the game says when they can play again. A visitor known only through their own claim still gets it; one known through a booking request, the chat, a sign-in or as a renter does not.',
        f'Won and not claimed: a small badge "Your 5% off is saved" with {B("Get my code")} and {B("Play again")} stays on the pages. On a later visit, at the moment a first game would show, the prize pops up by itself once as a small slide-in at the bottom ("Your 5% off is still waiting", the same two buttons), never as a card over the page; closed, it does not come back in that visit. Until they claim it or the prize ends after 14 days.',
        f'{B("Play again")} on a prize not claimed: a new, different game with a new draw. They keep the better of the two prizes and the other is closed, so there is only ever one code to claim: the card says "You won 15% off" or "You keep your 5% off". Once a visit and once a day (a setting).',
        'Every play wins: 5% off (54 in 100), 10% off (25), another go (15), 15% off (4), $50 off a rental of 3 days or more (1), 25% off up to $150 (0.6), $100 off a rental of 4 days or more (0.3) or one free day on a rental of 3 days or more (0.1). The prize is decided before the game starts; the game only shows it. The short terms with the game list the prizes and say the chances differ.',
        f'Another go: the card says "You won another go!" and {B("Play again")} starts a second, different game whose prize is drawn from the discounts only, so it always ends in a code. One replay at a time; it is never a code itself. Closed before pressing it, the card offers it again next time.',
        'The code (for example WIN-7KQ4-XM2P) comes off the rental charge only, up to $75 for a percentage, on one booking, within 7 days, one code a day per person, email, phone and device, never with another code. An earlier code not used yet stays good until it ends. The email with the code goes either way; a reminder goes 3 days before its last day and another the day before (Promo codes). Offers only with the marketing box ticked.',
        'On this device the code fills itself into the promo code box of the request form. Like every promo code, the discount is shared with the owner in the split.',
    ])
    g.task('Leads', f'{P("Bookings", "Renter leads")}.')
    g.steps([
        'The tiles: plays, claims, codes on booking requests, bookings, revenue and discounts from game codes in the last 30 days, then the same by game and by prize (Play again shows its plays; it has no claims).',
        'Each claim: when, the name (and "on the site now"), email and phone, the prize and game, the code and whether it is used (with the booking), marketing consent, and the visit: cars and pages viewed, minutes, city and device. A person who won again shows "2nd code of 2" under the name on each of their lines.',
        f'Press {B("Call")} or {B("Email")}, then {B("Contacted")} (it is yours). {B("Close")} with a reason when there is nothing more to do. A booking with the code marks the lead converted by itself.',
        'A visitor who viewed 3 cars or more also gets a Sales task, for example "Claimed 10% off, viewed 6 cars: Maya". It closes when the code goes on a request. A new code while that task is open is added to it, not a second task.',
    ])
    g.task('Contact details typed into forms', f'{P("Bookings", "Renter leads")}, the card "Typed into forms" at the top.')
    g.steps([
        'When someone types a name, email or phone into the request to book, the contact form, List your car, the owner application, Create an account, the discount game or the chat, it is saved as soon as each field is valid, even if they never press Send.',
        'Each line: when, the name (and "On the site now"), email and phone, the form, and Sent or Not sent. "Email not confirmed" means the account was opened from the form and the person has not opened the link we emailed them yet.',
        'After 30 minutes without sending, To do shows "Unfinished request from Maya Chen: follow up" (not raised from 23:00 to 07:00, the quiet hours of the site alerts). Call or email them; the task closes by itself when they send the form.',
        'Only what they typed is saved, and never used for offers without their consent.',
    ])
    g.tip('A new email gets an account at once (no password, email not confirmed) and one email "Continue your request" 30 minutes later, between 9:00 and 21:00. '
          'Until they open its link they cannot accept an offer, sign, pay or upload documents. An account never confirmed closes after 30 days; the lead stays. '
          f'It is on by default; the times and the To do are in {P("Settings", "Program")}, the card "Forms left unfinished".', label='Good to know')
    g.task('Settings', f'{P("Settings", "Discount games")}.')
    g.bullets([
        'On or off, the cap for percentage codes ($75), how long a code is good for (7 days), when it shows (2nd page view, 30 seconds, exit intent), the days a visitor keeps their prize (14: closing never draws a new one, and a prize not claimed pops up again until then), the days after a claim before the game comes back (1; 0 is one code per person ever), how often Play again works on a prize not claimed (once a day; 0 turns it off), and the cars viewed for a Sales task (3). The reminders before a code ends are under Promo codes.',
        'After a visitor closes a game, the next card shows on their 3rd page view after the close (any page) or 2 minutes later, whichever first; at most 4 in one visit, no daily cap unless you set one. A prize waiting for them pops up once a visit only. All are settings. Never on booking, payment or signing pages; the request-to-book form has its own game.',
        f'Prizes and games: each prize with its percent, dollars or free days, a minimum rental length, its cap and its chance, or Play again (another go, at most one); each game\'s weight (0 turns it off). Press {B("Save prizes and games")}. Codes already sent keep their value.',
    ])

    # ---------------------------------------------------------------- referral partners (0164)
    g.chapter('Referral partners and RentalCoverage',
              'Body shops and tow truck companies (and, if you want, dealerships and insurance brokers) can send you renters and earn a kickback when the rental is finished and paid in full. A separate switch adds an optional affiliate link to RentalCoverage on the pages that talk about coverage. Nothing in either program is shown to renters until you set it up.',
              blurb='Body shops and tow trucks that send renters: sign-ups, links and flyers, earnings and payments; and the optional RentalCoverage link.')
    g.task('Add a partner', f'{P("People", "Referral partners")}, then {B("Add a partner")}.')
    g.steps([
        'Choose the kind (body shop, tow truck company, dealership or insurance broker) and type the business name, the contact, phone and email. Start typing the address: the city and postal code fill in.',
        'Choose how you pay them (e-Transfer, cheque, bank transfer, cash or another way) and, for e-Transfer, the email to pay.',
        f'Choose the kickback: a flat amount for each completed rental ($50 unless you change it) or a percentage of the rental charge (10% unless you change it). The percentage applies to the rental charge after discounts only, never to add-ons, fees or taxes. The two defaults are under {P("Settings", "Program")}, Referral partners.',
        f'Press {B("Save")}. A partner you add is active at once, with a code, a short link and a flyer.',
    ])
    g.task('Approve a sign-up', 'The public pages carmacars.ca/partners/body-shops and carmacars.ca/partners/tow-trucks have a sign-up form. A sign-up is a pending partner and a task for you; it earns nothing and its code ties no rental until you approve it.')
    g.steps([
        f'Open {P("People", "Referral partners")}. A sign-up shows as Waiting for approval, and the Partners tab shows how many are waiting.',
        f'Open the partner and check the business. Press {B("Approve")} (or {B("Decline")}: they are not told by email).',
        f'Press {B("Write them their link")}. It opens an email to them with their link and code; attach the flyer from the next section before you send it.',
    ])
    g.task('The link, the QR code and the flyer', 'Open the partner. The card "Link, QR code and flyer" shows everything they hand out.')
    g.bullets([
        'The short link is carmacars.ca/r/ and their code, for example carmacars.ca/r/BODY1234. A renter who opens it keeps the partner for 60 days on that device, even if they book later.',
        f'Press {B("Flyer for the counter (PDF)")} for a one-page flyer with their name, their code and a QR code of the link. Print it or send it.',
        'A renter can also type the code in "Did someone refer you?" on the request to book. A code typed there wins over the link. A code nobody holds is ignored.',
        'Changing the code ends the old link, QR code and flyer. Pausing or ending a partner stops new rentals from being tied to them; what they already earned stays.',
    ])
    g.task('Rentals you add by hand', f'{P("Bookings", "Add a rental")}, field "Referred by (partner code)".')
    g.steps([
        'Type the partner\'s code if a body shop or tow truck sent the renter. A code that does not exist or is not active is refused, so a typing mistake shows at once.',
        f'Forgot it? Open the partner and press {B("Tie a booking")}: enter the booking number and why. This is not possible once a kickback on that booking is approved or paid, nor on a booking that already has an owner or field staff member as its referrer (one referrer per booking: owner, then field staff, then the partner).',
    ])
    g.task('Earnings and payments', f'{P("People", "Referral partners")}, the tabs Partners, Kickbacks and Payments made.')
    g.steps([
        'A kickback starts as "Rental not finished yet". It is earned when the booking is completed and paid in full and no payment is in dispute; it then waits as "Pending approval".',
        f'Check it on the Kickbacks tab and press {B("Approve")} (or {B("Approve all")} for one partner).',
        f'Pay the partner the way you agreed, then press {B("Record a payment")} on their line: it settles every approved kickback and keeps the reference.',
        f'A refund or a lost dispute after the kickback was earned takes it back (a reversal line). If it was already paid, the reversal stays on the ledger as a negative line for you to settle with the partner. Use {B("Reverse")} to take one back yourself, with a reason.',
    ])
    g.tip('The kickback is a booking expense, taken before the owner\'s share is worked out, in the same line as staff commissions on the owner statement. Check the owner agreement wording on kickbacks before you start paying partners.', label='Good to know')
    g.task('The partner\'s own page', 'The card "Link, QR code and flyer" shows a private page address for the partner. Send it only to them.')
    g.bullets([
        'It shows their link and code, their referrals by the customer\'s first name and the month only, what is waiting and what was paid. No sign-in: the long address is the key.',
        f'Press {B("New private page link")} if it was shared by mistake: the old address stops working at once.',
    ])
    g.task('RentalCoverage affiliate', f'{P("Settings", "RentalCoverage affiliate")}. It is off until you join the affiliate program and paste your link.')
    g.steps([
        'Join RentalCoverage\'s affiliate program (their affiliate dashboard gives you a tracking link, and sometimes an ID).',
        f'Press {B("Paste the affiliate link")}. Paste the link exactly as the dashboard gives it. If it has {{id}} in it, type your ID in the next field and it is filled in. Leave "Show the link on the site" ticked and press {B("Save")}.',
        'The link now shows on Requirements and coverage, the credit card coverage guide and the coverage step of the request to book. Each says it is a separate company\'s optional product, that it does not replace the coverage option the renter chooses, that CarmaCars may earn a commission and that it costs the renter nothing extra. It says nothing about what the product covers.',
        'Untick "Show the link on the site" any time to turn it off everywhere.',
    ])
    g.bullets([
        'Every click goes through a CarmaCars address that counts it by place and month (and by booking when the renter has one) and adds utm_source=carmacars, utm_medium=referral and utm_campaign=coverage_ and the place.',
        f'The page shows clicks by place and month and the latest clicks. RentalCoverage reports the sales, not the site: when they pay you, press {B("Add a payment received")} with the date, amount and reference.',
    ])

    # ---------------------------------------------------------------- hiring (0173)
    g.chapter('Hiring',
              'Candidates apply on carmacars.ca/careers. Every application is scored on the server against the role\'s rubric: a candidate who passes gets a link to book a 15-minute call, one who does not qualify for Field staff is offered Sales instead, and the rest wait for you. During each call you fill in a rubric; the final score ranks everyone in the role.',
              blurb='Open roles and apply links for Indeed and OnlineJobs.ph, the applications and their scores, interview days, the rubric during each call, the ranked shortlist and Hire.')
    g.task('Open a role and send the apply link', f'{P("People", "Hiring")}, tab Roles and links.')
    g.steps([
        f'Press {B("Open the role")} to put it on carmacars.ca/careers (and in the sitemap and the footer); {B("Close the role")} takes it off. Field staff, Sales in person and Remote sales start open; the three remote assistant roles start closed.',
        'Copy the apply link: it ends with ?src=indeed (or ?src=onlinejobs for the remote roles), so each application records where it came from.',
        'Copy the message under it and paste it into Indeed (or OnlineJobs.ph) messages to each applicant. It asks them to answer the role\'s questions, about five minutes.',
        f'{B("Pass mark and pay")} changes the pass mark (60 of 100 unless you change it) and the pay shown on the page.',
    ])
    g.task('What happens to each application', 'The database scores the answers the moment they arrive. The candidate never sees the points.')
    g.bullets([
        'Score at or above the pass mark, no knock-out: an email with a personal link to book a call (Invited).',
        'Field staff who do not qualify (no full G licence, under three years of driving, or a low score) are not declined: they get a friendly email offering Sales in person, with a one-click link that fills in their details, and Remote sales named as the other choice (Referred). If they already applied for Sales, nothing is sent and a note says so.',
        'Sales in person below the pass mark, or remote only, is offered Remote sales. A remote assistant role below the pass mark is offered the closest other open role.',
        'A knock-out with no other role to offer (for example the finance code word missing) gets a polite decline.',
        'Anyone else waits for you as Below the bar, with only a confirmation email.',
    ])
    g.task('Review the applications', f'{P("People", "Hiring")}, tab Applications.')
    g.steps([
        'Filter by role, status, source (Indeed, OnlineJobs.ph, website, referral) or score. Open a candidate for every answer with the points it earned and any knock-out.',
        f'{B("Invite anyway")} sends the booking link to a candidate below the bar, declined or referred. {B("Decline")} sends the polite decline email (untick it to decline without an email).',
        'A candidate referred to another role shows the link both ways under Linked applications.',
    ])
    g.task('Interview days', f'{P("People", "Hiring")}, tab Interview days.')
    g.steps([
        f'Press {B("Add an interview day")}: the day, from and to (Toronto time), the call length (15 minutes) and the break between calls (5 minutes), phone or video, and the roles it is for (empty: every role).',
        'Phone: you call the candidate on the number they gave. Video: every booking gets its own Jitsi Meet link, in the candidate\'s email and on their page.',
        'Candidates book, move or cancel from their link. They get a confirmation, a reminder the evening before and one an hour before (and a text, when phone and texts are on). Remote roles show Manila time too.',
        f'{B("Turn off")} stops new bookings on a day; a day with bookings cannot be deleted.',
    ])
    g.task('Run the calls with the rubric', f'{P("People", "Hiring")}, tab Calls.')
    g.steps([
        f'Pick the day. Each call shows the time, the candidate, Call (or the video link). Press {B("Start")}.',
        'The rubric sits beside the call guide (what to ask each minute, and what a good answer sounds like). Score each line 1 to 5: Communication, Reliability and availability, Role skills, Customer or sales instinct, Judgement on the scenarios, Attitude.',
        f'Choose the decision (Hire, Maybe, No, No show), add notes and press {B("Save the rubric")}. The interview score (of 100) and the final score (40% screening, 60% interview) fill in, with the rank in the role.',
    ])
    g.task('Shortlist and Hire', f'{P("People", "Hiring")}, tab Shortlist.')
    g.steps([
        'Each role lists its interviewed candidates by final score, rank 1 first.',
        f'Open the candidate and press {B("Hire")}. It invites them into the right portal: field staff, or the assistant portal (both sales roles are the Sales function, with in person or remote recorded).',
        f'Then press {B("Send the agreement to sign")}: check the values and send the staff agreement to sign in their portal.',
        f'{B("Not hired")} closes a candidate after the call without an email; {B("Withdrawn")} is for one who no longer wants the role.',
    ])
    g.tip('Applications are for Admins only. The name, contact details and answers of a candidate who is not hired are deleted 12 months after the decision, as the privacy policy says.', label='Good to know')

    # ---------------------------------------------------------------- advertising and owner recruitment (0167)
    g.chapter('Advertising and owner recruitment',
              'Marketing writes the text of every ad from the car\'s own record, keeps track of where each ad is posted, tells the sales assistants when an ad needs updating, shows which channels bring bookings, drafts the week\'s Facebook Page and Instagram posts and keeps the consent log for owner recruitment. Nothing is posted by the server: you post by hand, and Facebook Marketplace from the owner\'s own profile.',
              blurb='Ad text for each car and channel, posted ads and their update tasks, bookings by channel, social drafts, Meta publishing, owner recruitment and its consent log.')
    g.task('Write an ad', f'{P("Marketing", "Listings")}.')
    g.steps([
        f'Choose the car and the channel (Facebook Marketplace, Kijiji, Craigslist, Instagram, Facebook Page or Google Business Profile) and press {B("Write it")}.',
        'Copy each part with its button: the title, the price line, the description (or caption), the hashtags and the tracked link. Each shows its length against the channel\'s limit (a Kijiji title takes 64 characters, Craigslist 70, an Instagram caption 2,200, a Google post 1,500).',
        'Add the photos in the order shown: the first is the cover. Open a photo to save it.',
        f'Post the ad on the site, then press {B("Mark as posted")} and paste its address and the date.',
    ])
    g.bullets([
        'The text comes from the car\'s record only: the rates, kilometres, deposit, delivery fee, who may rent it and the car code. A fact the record does not have is left out. No review, rating or claim is added.',
        'The tracked link opens the car\'s page with utm_source (the channel), utm_medium and utm_campaign (the car code), so the request counts under that channel.',
        'A warning shows when the car does not take requests, has no daily rate, or shows sample photos (take real photos first: an ad shows the car itself).',
        'Facebook Marketplace is posted from the owner\'s own Facebook profile in their browser: Meta does not take vehicle listings from business Pages. Kijiji takes one ad per car, in one category and one region. An Instagram caption cannot hold a working link: put it in the bio or a story link sticker.',
    ])
    g.task('When an ad needs updating', f'{P("Marketing", "Posted ads")}, or the task in {P("Today", "Staff tasks")}.')
    g.steps([
        'A change of 3% or more in a car\'s daily, weekend, weekly or 30-day rate, any change of its deposit, kilometres, extra-km price or delivery fee, or the car leaving the site marks each of its live ads Needs updating and opens a task for the sales assistants (for example Update the Kijiji ad and the car). The task says what changed, the new price line and the ad\'s address.',
        f'Press {B("New text")}, copy the new text and update the ad on the site.',
        f'Press {B("Mark the ad updated")}. The task closes. Closing the task in Staff tasks counts too.',
        f'Car off the site: take the ad down and press {B("Taken down")}. If the car comes back at the same rates first, the task is cancelled by itself.',
    ])
    g.tip(f'The 3% is under {P("Settings", "Program")}, Advertising and owner recruitment. The rates are checked again every 6 hours, so a rate dated ahead is caught on its day.', label='Good to know')
    g.task('Bookings by channel', f'{P("Marketing", "Bookings by channel")}.')
    g.bullets([
        'Every request of the dates chosen counts once: under the source staff set on the booking, else the renter\'s visit (the campaign source of a tracked link, or the site they came from), else a referral code, else how it reached us (phone, email, WhatsApp).',
        'Choose the last visit before the request or the first visit. A booking is a request that was confirmed, paid or completed; revenue is its rental charge after discounts. The months add up to the Bookings list.',
        'The visit is kept with the request when it is sent, so the source outlives the 90 days of visit history. A visitor who refused analytics cookies has no source.',
        f'On a booking, the line Came from shows the source. Press {B("Set")} to give it by hand when the renter told you (a Kijiji reply, a walk-in, word of mouth).',
    ])
    g.task('Facebook Page and Instagram drafts', f'{P("Marketing", "Social drafts")}.')
    g.steps([
        f'The week\'s drafts are written from the fleet every 6 hours, for this week and the next: Monday a new car (published in the last 14 days) or a featured one; Tuesday the owner program; Thursday the cars free this weekend; Friday the requirements (Instagram); Sunday a price highlight or a seasonal trip (Facebook Page). Press {B("Write drafts for this week")} to write them now.',
        f'Read each draft. Press {B("Edit")} to change the caption, the channels or the day, then {B("Approve")}; or press {B("Skip")}.',
        f'Copy the caption for each channel (on the Facebook Page the tracked link is in the text; for Instagram copy the link for the bio), post it with the photos shown, then press {B("Posted on Instagram")} or {B("Posted on Facebook Page")} and paste the post\'s address.',
    ])
    g.bullets([
        'Wednesday\'s walkaround video and Saturday\'s handover story are filmed by field staff. No renter is shown without written consent.',
        f'Press {B("Add a post of your own")} at the bottom of the week for anything else.',
    ])
    g.task('Meta publishing (off until set up)', f'{P("Settings", "Meta publishing")}. Until it is on, every post is copied and posted by hand.')
    g.steps([
        'Make the Instagram account a professional account and link it to the CarmaCars Facebook Page.',
        'At developers.facebook.com, create a Business app owned by the CarmaCars business portfolio. Give it the permissions pages_show_list, pages_read_engagement, pages_manage_posts, instagram_basic and instagram_content_publish, and make a long-lived Page access token. Meta may ask for App Review before posts are public.',
        f'Press {B("Enter the details")}: the Page id, the Instagram account id and the token. The token goes to the vault; the page shows only its last four characters.',
        f'Press {B("Switch on")}. Approved drafts then go out on their day and their post links are recorded; a refusal shows on the draft. Press {B("Switch off")} or {B("Remove the token")} at any time.',
    ])
    g.task('Owner recruitment', f'{P("Marketing", "Owner recruitment")}.')
    g.para('Owners and co-hosts are found in classified ads. The anti-spam law (CASL) does not cover a live phone call, but an email or a text needs consent, names the sender and offers an unsubscribe. The lawyer confirms the approach before outreach starts.')
    g.steps([
        f'Press {B("Add a lead")}: paste the ad\'s address, choose who is selling (a private seller, a dealer or a rental business) and type the name, the phone and the car from the ad. Nothing is collected from the classified site.',
        f'Call them with the script on the lead\'s page and press {B("Log the call")}. A yes needs their words ("Yes, text me the details"): they become express consent in the log. A no means do not contact, ever.',
        f'When the lead\'s page says email or text is allowed, choose a template, check the words and press {B("Send")}. The email adds CarmaCars\' name, mailing address and the unsubscribe link; the text ends with "Reply STOP to opt out." Texts wait for 8 am during quiet hours.',
    ])
    g.bullets([
        f'Press {B("Record consent")} for consent given another way: express (with its proof), implied by their inquiry (6 months), implied by a business relationship (2 years), a business address published with no "no solicitation" note (never a private seller), or one message after a referral (naming the referrer).',
        'The consent log is never edited: a change is a new line. An unsubscribe or a STOP reply adds a withdrawal by itself, and nothing more goes on that channel.',
        f'A message without consent is refused with the reason. {P("Settings", "Program")} has a switch that stops all recruitment messages.',
    ])
    g.tip('Keep the proof of an oral yes: a recording, or a note written during the call with the time. Consent you cannot show does not count.', label='Watch out')

    # ---------------------------------------------------------------- 9
    g.chapter('Search: car pages, landing pages and guides',
              'The text of every car page, the landing pages for each area and way of renting, and the guides are written '
              'every day by a scheduled Claude session from the facts in the database, checked with the site\'s own checks and published by themselves '
              '(the website\'s Workers AI writer is off, so the free AI allowance stays with the staff assistant). Nobody has to type or review '
              'anything. You can still change any line; what you change is kept.',
              blurb='Car copy written by itself, landing pages, place pages for every place and term, detailing and body shop, guides, business listings and IndexNow.')
    g.task('The copy of a car', f'{P("Cars", "Vehicles")}, then the car, then its Listing tab. The same card is on the listing review.')
    g.steps([
        'The card says who wrote the text: a plain copy from the car\'s facts while the written copy is prepared (the next daily batch), then the batch (claude-batch) or Workers AI.',
        'Every field is shown: search title and description, heading, introduction, highlights, good for, what\'s included, pickup and delivery, requirements, questions and the photo descriptions.',
        f'To change a field press {B("Change")}, then {B("Save and lock")}. A locked field is kept by every new version. {B("Unlock")} lets it be written again.',
        f'{B("Write again")} asks for a new version now. A new version is also written by itself when the car\'s facts change: its rates, specs, area or photos.',
    ])
    g.tip('The checks refuse long dashes, sales words, the numbered company, any number that is not in the car\'s facts (a price, a seat '
          'count) and equipment the facts do not list. A version that fails is asked again with the problems named; if it still fails, the '
          'page keeps its current text and it is tried again later.', label='Good to know')
    g.task('Landing pages and guides', f'{P("Settings", "All settings")}, then Search.')
    g.steps([
        'Today: the Workers AI used for search copy and in all, and IndexNow (addresses waiting and sent).',
        'Car copy: every real car, who wrote its text, and whether its facts changed since.',
        'Landing pages: each place and way of renting, whether it is in search, its cars and who wrote it. A page for a way of renting (monthly, SUV) goes into search once enough real cars match it (Program settings).',
        f'Open {B("Edit")} on a page or a guide to change its text. Edited fields are locked. {B("Write again")} asks for a new version; on a guide, the brief says what it must cover.',
    ])
    g.task('Vehicle pages', f'{P("Settings", "Vehicle pages")}. A page for every make, model, model year and Canadian trim of every year, at carmacars.ca/cars/make/model/year/trim, with our cars below it; each trim also in every place and in 12 colours (a black 2020 Volkswagen Jetta Sportline in Mississauga, for example); every page again for sale (carmacars.ca/buy/...) and for each search term: renting (car hire), sale (financing), detailing (ceramic coating) and body shop (bumper repair), at carmacars.ca/t/term/...')
    g.steps([
        'Pages: how many pages each level and each tier has, the total, and how many are in search. Every page is in search by default; nothing needs setting up.',
        f'One switch per tier takes it out of search at once: {B("Index the place pages")}, {B("Index the colour pages")}, {B("Index the search term pages")}, {B("Index the /buy pages")}, {B("Index the detailing pages")}, {B("Index the body shop pages")}. Off, those pages stay visible but leave the sitemaps and search.',
        'The places are the place list of the local search release (every city, town and neighbourhood, with GTA and country levels); until it is filled, the area landing pages. The search terms are edited with them.',
        f'{B("Financing disclaimer")}: the text on financing and leasing pages. CarmaCars never says it lends or leases.',
        'Database: its size against the cap the catalog and places imports keep under: the cap of the Database plan (Pro, 6,144 MB, by default; Free, 450 MB). IndexNow: the addresses sent today, where the sweep is, and any back-off; nothing to do.',
        'Each page is built from data: the EPA fuel-use ratings in litres per 100 km, the cost to drive 100 km at the gas or electricity price set here, what changed from the year before, how a trim differs from the others, similar models, and the rental questions from the program settings.',
        'Below the facts: our cars of that exact year, model and trim, then the same model in other years, then similar cars free now, and Request it, which sends an enquiry to Bookings > Leads.',
        f'Settings: {B("Index every page")} (the default) or {B("Only pages that pass the rules")}: makes, models with 2 or more years of data, years with one of our cars or of a popular model from 2015, trims with one of our cars. The others stay visible but out of search. Also the gas, premium and electricity prices, and how often the catalog is imported (every 30 days).',
        f'Canadian trims: open a model and type one line per run of years, entry trim first: 2020-2021: Comfortline, Highline, Sportline, Execline. Your lines are kept by every import; empty them to go back to the CarmaCars list. {B("Add trims for another model")} adds a model that has none.',
        f'Catalog import: the last import and its counts. {B("Import now")} asks for a new one; it runs at the next daily check, at 07:17 UTC.',
    ])
    g.tip('A car joins its pages by itself once it is on the site: its make, model, year and trim are read from the car. A trim that names several (S / SE / R-Line) leaves the car on the year page only; set the car\'s trim to one Canadian name to put it on the trim page.', label='Good to know')
    g.task('Stock photos on the vehicle pages', f'{P("Settings", "Vehicle pages")}, card Stock photos. The vehicle pages show a real photo of the make, model and generation at the top (a 2015 Camry page shows a Camry of the 2012 to 2017 generation), with the credit always under it: "Photo: author, licence, Wikimedia Commons". The place pages and the detailing and body shop pages show a photo of a road, a car being detailed or a body shop. Our own cars always show their own photos.')
    g.steps([
        "Nothing to set up: the photos come by themselves every day, our fleet's models and the popular models first. Only free licences are used (public domain, CC0, CC BY, CC BY-SA), from Wikimedia Commons, or Openverse when Commons has none. A year without a photo of its own generation shows the nearest photo of the model, marked \"not the exact year\"; a model with no photo keeps the studio drawing.",
        'The card shows how many models and model years have a photo, the popular models still without one, and the last run.',
        f'Open a make to see its photos. A wrong car, a poor photo or a photo you do not want: press {B("Hide")}. The page goes back to the studio drawing at once, and that photo is never picked again.',
        f'{B("Pick again")} asks for the next best photo; {B("Replace")} takes a photo you found on Wikimedia Commons: paste its address (https://commons.wikimedia.org/wiki/File:...). Either is done at the next daily run, after its licence is checked. A photo whose licence is not allowed is refused, with the reason.',
        f'{B("Show stock photos")} in the settings above turns every stock photo off at once (on by default).',
    ])
    g.tip("Never upload or use a photo from Google, a dealer or a manufacturer's site here: only Wikimedia Commons files, with the credit the page shows.", label='Good to know')
    g.task('A car for sale', f'{P("Cars", "Vehicles")}, then the car. On the For sale card, tick {B("For sale")}, enter the Asking price and press {B("Save")}.')
    g.steps([
        'The car then shows at the top of its /buy pages (its make, model, year and trim) with the asking price, the only time a page says a car is for sale.',
        'Untick it when the car is sold or no longer for sale: the pages say so at once.',
        f'"Find me this car" on the /buy pages sends a buyer lead to Sales (staff portal: {B("Owner leads")}, Buyer leads), with a To do line.',
    ])
    g.task('Search engines and business listings', f'{P("Settings", "All settings")}, then Site settings.')
    g.steps([
        'Search engines: paste the Google Search Console value (HTML tag) or the file name (HTML file), and the Bing value. The steps are on the card.',
        'Business name, address and phone: the exact text for every listing, and the description and categories.',
        f'Business listings: press {B("Copy")} beside each line and paste it into Google Business Profile, Bing Places, Apple Business Connect, Yelp, Yellow Pages and Facebook. Tick each one when it is done.',
    ])
    g.tip('Changed pages are sent to IndexNow (Bing and the other engines that use it) by themselves. Google reads the sitemap: submit '
          'carmacars.ca/sitemap.xml once in Search Console.', label='Good to know')
    g.task('Place pages',
           'Every place we have, from a country down to a neighbourhood, gets a page for every term people search with: renting (car hire, '
           'SUV rental, monthly car rental ...), buying help (used cars, car financing ...), detailing (ceramic coating, window tint ...) and '
           'body work (collision repair, dent repair ...). Each page is written from real data only: the distance from us, the delivery price '
           'within our reach, the nearest airport, the landmarks near it, our live cars and the places around it. A place far from Toronto '
           f'says we serve the Toronto area and takes a request instead. {P("Settings", "All settings")}, then Search.')
    g.steps([
        'Place pages: four switches, one for each family, put the pages in search and in the sitemaps. All four are on.',
        'Quality gate: off. On, only places within the delivery reach are in search, and rental pages only with a real matching car. Search engines can treat many similar pages as low value; the gate lowers that risk.',
        'Delivery reach: places within this distance of our location are offered delivery. Database size cap: the places import stops before the database passes it.',
        'Regions and places: every province, state and territory is on. Untick a region to take its pages and sitemaps off the site.',
        'Terms and services: change a term\'s title or what is true about it, point a synonym to another term (its pages then leave search), switch a term off, or add one. Give a service a starting price, or leave it empty for "price on request".',
    ])
    g.tip('A region has pages once the places workflow has loaded it: GitHub, Actions, places, Run workflow, with the regions or all. '
          'The run loads Ontario first and names any region it skipped because of the size cap.', label='Good to know')
    g.task('Requests from the place pages',
           f'The buying help, detailing and body shop pages, and the pages of places beyond our reach, have a request form. Each request is a lead with a task in {B("To do")}: '
           'detailing and body shop requests are due within an hour of opening and show in Today. Buying help pages say plainly that CarmaCars does not sell, finance or '
           'lease cars; the notice at the top is set under Place pages.')
    g.para('Mechanical work has pages too, under the body shop pages and listed apart as "Auto services we arrange": a mechanic, oil changes, '
           'brakes, tires and winter tires, towing, batteries and boosts, alignment, transmission and engine repair, diagnostics, inspections and '
           'the Ontario safety certificate, emissions, AC, exhaust and suspension. CarmaCars does not do this work, and the pages say so: each takes '
           'a request (a "Mechanical work to arrange" task, due within an hour of opening) and offers a rental while the car is in. '
           'They have no questions of their own; their per car pages (for each make, model, year and trim) say the same and take the same request.')
    g.task('One name, address and phone',
           'The footer, the contact page, the structured data and every business listing show the business address of Site settings. '
           'Keep it the address renters come to, and change it there only.')

    g.chapter('Settings',
              'Settings change the public site and the rules of the program at once. Program settings are kept '
              'as dated rows, so earlier values stay on record.',
              blurb='Site, program settings, official forms mapping, insurers and the other lists.')
    g.task('The Settings page')
    g.steps([
        f'Site setup lists what is still missing on the public site, with {B("Open site settings")}.',
        'Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.',
        'Program settings: every timing and policy value.',
        'Forms: Blind Spot\'s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.',
        'Insurers: insurance companies billed for bookings.',
    ], shot=S('admin/24-settings-desktop', 0, 0, 1440, 900, pins=[(1, 470, 297), (2, 372, 362), (3, 1115, 362), (4, 372, 659), (5, 372, 764)]))
    g.para('The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, '
           'Airports and delivery, Protection Plan prices, Card coverage, Reviews, Text alerts, Partners (each partner company\'s CRM link: see Partners, company cars and rentals added by hand), '
           'Email aliases and reply-to, Staff and roles, Promo codes and Quick replies.')

    g.task('Program settings')
    g.steps([
        'Turnaround between trips: the time held between two trips. The cleaning block after a trip is this time.',
        'Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.',
        'First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.',
        'Staff commissions and prices typed by hand: the commission outside Sales (10%), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month\'s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).',
        f'Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press {B("Save the defaults")}.',
        'Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.',
        'Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).',
        'Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.',
        'Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-out besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).',
        'Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.',
        'Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.',
        f'Change a value and press {B("Save")}. It is saved as a new row from today; the rows before stay as they were.',
    ], shot=S('admin/25-program-settings-desktop', 0, 0, 1440, 1000, pins=[(1, 372, 220), (2, 400, 490)]))

    g.task('Vehicle class rules', f'Open {B("Settings")}, then {B("Vehicle class rules")}. How a new car\'s class is decided from its VIN: the first rule that matches wins.')
    g.steps([
        'The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.',
        f'Press {B("Add a rule")} or {B("Change")}: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.',
        f'{B("Try a car")} gives the class the rules decide for a year, make, model, trim and body, and why.',
        f'{B("Delete")} removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.',
    ])
    g.tip('A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.')

    g.task('Official ServiceOntario forms', 'The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.')
    g.steps([
        f'Open {P("Settings", "Forms")}. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.',
        f'Press {B("Download a filled preview")} for one car and check each value against the form.',
        'Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Press Save the mapping.',
        f'Press {B("Checked: use for owners")}. Every owner\'s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with {B("Record paper signature")}. Each form not checked yet is also a line on To do with the same button and Preview it.',
        f'A new version from ServiceOntario? Press {B("Upload the official fillable PDF")}: the fields of the same name keep their mapping.',
    ])
    g.tip('SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company\'s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner\'s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form\'s notes list what to tick or choose at the counter.', label='Good to know')

    g.task('Blind Spot rental agreement', 'We rent under Blind Spot Car Rental\'s insurance, so every booking has two agreements: CarmaCars\' rental agreement and Blind Spot\'s own. Blind Spot\'s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.')
    g.steps([
        f'Open {P("Settings", "Forms")}. The Blind Spot Car Rental agreement card is first. Press {B("Upload Blind Spot\'s PDF")} and choose Blind Spot\'s blank form (2 pages, A4).',
        f'Press {B("Download the filled sample")}: a made-up booking on the form. {B("Sample billed to an insurer")} also fills the claim number, the adjuster and the insurance company. Check every box.',
        'On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars\' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative\'s signature instead of Sam\'s.',
        f'Press {B("Checked: use for bookings")}. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.',
        'Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.',
        f'A new version of Blind Spot\'s form? Upload it the same way: it waits for {B("Checked: use for bookings")}, and bookings keep the version in use until then.',
    ])
    g.tip('Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the daily rate and the rental charge, the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST, total and deposit, and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. Initials, fuel and the boxes filled at return stay blank.', label='Good to know')
    g.para('The renter\'s signature goes in boxes 16, 17 and 20 of the signed copy, with a signature record page. Both agreements are in the booking\'s Drivers and documents tab, in the renter\'s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.')

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
        f'Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in {P("Money", "Insurer rates")}.',
        f'To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press {B("Add")}.',
        'Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.',
    ])

    g.task('Promo codes: end dates and reminders', f'{P("Settings", "All settings")}, {B("Promo codes")}.')
    g.bullets([
        'Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.',
        'A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.',
        'A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".',
        'A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.',
        'The list shows each code\'s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.',
    ])

    g.task('Card coverage: which credit cards include rental car coverage', f'{P("Settings", "Card coverage")} is the list renters see at {U("carmacars.ca/credit-card-rental-coverage")} and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.')
    g.steps([
        'The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer\'s own document, and when it was last checked.',
        f'Open a card under Change a card, open its official guide, correct what changed and press {B("Save")}. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.',
        'A card whose numbers come from a published summary has Read in the issuer\'s own document unticked and the summary\'s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer\'s guide.',
        f'Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.',
    ])
    g.tip('A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer\'s guide.')

    g.task('Reviews: review requests and Google', f'{P("Settings", "Reviews")}: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.')
    g.steps([
        'When review requests go: the check-in (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-in), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.',
        'The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile\'s own review link.',
        f'Google Business Profile: press {B("Connect Google")} and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.',
        f'A clear match stops that renter\'s reminders at once. A possible match waits in Reviews: press {B("Confirm")}, {B("Not this renter")} or {B("Match to a booking")}.',
    ])
    g.tip('Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.')

    # ---------------------------------------------------------------- 10
    g.chapter('Add-ons',
              'Add-ons are things renters buy with a rental. They are on, with prices set, from the start: change any of them '
              'when you want.',
              blurb='The catalogue, prices, which cars, notice, stock, confirmation and the money.')
    g.task('The catalogue', f'Open {P("Settings", "Add-ons")}.')
    g.steps([
        'Each add-on shows its price, whether it is on, the notice it needs, its stock and how many are booked in the next 30 days.',
        f'Press {B("Edit")} to change it: name, short description, price, Priced (per trip, per day or per hour), the most per trip, the most days, the minimum hours, HST.',
        'Price by car: one line each, such as suv premium = 110 or body:van = 110. The first that matches the car wins.',
        'Which cars: only some classes, only some cars, cars left out, fuel types left out (prepaid fuel is not for electric cars), months (winter tires October to April).',
        'Notice needed in hours, In stock for physical items, the most on one booking, staff confirmation (a chauffeur), a Fleet task to get it ready (flowers, a chauffeur), and Not refunded once its notice has started.',
        f'Press {B("Save")}. Add a photo with {B("Add a photo")}. {B("Add an add-on")} at the bottom adds a new one; it stays off until it has a price.',
    ])
    g.table([
        ['Flowers', '$150 a trip, 24 hours notice, Fleet prepares'],
        ['Baby seat (rear-facing), Child seat', '$15 a day, up to $75 a trip, 2 in stock each'],
        ['Booster seat', '$10 a day, up to $50 a trip, 2 in stock'],
        ['Chauffeur', '$45 an hour, 3 hours minimum, staff confirm, 24 hours notice'],
        ['Umbrella, Phone charger', '$5 a trip, 4 in stock each'],
        ['Full tank of gas (prepaid)', '$85 a trip; $110 for SUVs, vans and premium cars; not for electric cars'],
        ['Winter tires', '$15 a day, up to $150, October to April'],
    ], head=['Add-on', 'As set at launch'])
    g.task('Where renters and staff see them')
    g.bullets([
        'The car page (Add-ons, priced live) and step 4 of the request.',
        'Offers and rentals added by hand: staff tick them; a chauffeur is confirmed with the offer.',
        'The renter portal: add one until 24 hours before pickup (Program settings, addon_portal_cutoff_hours) or the add-on\'s own notice, charged on the card on file.',
        'The agreement summary, the offer, the receipt and the statement list each add-on as a line.',
        'Field staff see what to put in the car on the handover, and the prepaid fuel note.',
    ])
    g.task('The money')
    g.bullets([
        f'An add-on a renter adds with no card on file waits for payment: the renter pays it on the booking ({B("Pay for your add-ons")}), and the Finance task closes by itself. Paid another way, record it on the booking.',
        'Add-on revenue is CarmaCars\' own: never Owner Revenue or a partner\'s share, and never in a commission or kickback base.',
        'The company statement shows Add-ons as its own income line (account 4150).',
        'A cancellation refunds add-ons by the booking\'s tier, except one marked Not refunded once its notice has started.',
        'Removing a paid add-on after booking creates a refund for it, waiting for approval.',
    ])

    # ---------------------------------------------------------------- the investor deck (0083)
    g.chapter('The investor deck',
              f'The investor deck is a slide deck in the investor portal at {U("/investor/deck")}. Signed-in investors see it while it is shown; Admins always see it. '
              'Its figures come from the database when it opens: the owner fee tiers, the partner commission, the real cars\' public rates, delivery, add-ons and renter fees, '
              'the deductible and deposits, and the investment terms of Program settings.',
              blurb='Preview the deck, show or hide it, and set its multiplier and percentage.')
    g.task('Preview and settings')
    g.steps([
        f'Go to {B("Investors")} and press {B("Investor deck")}. The button says whether investors see it now.',
        'The page shows the settings, then the whole deck as investors see it.',
        f'{B("Show the deck to investors")}: on, investors see it under Investor deck and on their Investments page; off, only Admins see it.',
        f'{B("Multiplier on the money we invest (x)")}: the company\'s own figure, shown large on the profitability slide with its footnote (internal, not audited).',
        f'{B("Yearly percentage of the current offer (%)")}: used by the worked examples and the calculator. Each investor\'s own percentage is the one in their agreement.',
        f'Press {B("Save deck settings")}. Every change is in the audit log.',
    ])
    g.para(f'To hide or show it in one click, use {B("Hide the deck from investors")} or {B("Show the deck to investors")} on Investors.')
    g.para('How we make money is one slide with the seven revenue lines: our own cars, owners\' cars fully managed with coverage under our fleet policy, '
           'coverage under our fleet policy for owners who manage their own cars, Turo management, brokering partner fleets with the chauffeur service, detailing, and the body shop. '
           'The features include maintenance and service tracking, phone number sign-in, saving contacts from unfinished forms and smart Turo car matching, and the newest: the redesigned renter, owner, investor, assistant, field and Admin screens, '
           'terms car by car, deposits settled after the bills come in, offers and rentals added fast, the staff assistant, and promo code end dates. Their screens in the deck are real screens with fictional people.')
    g.tip('The deck shows no internal costs, fleet counts or staff pay. Every example is labelled as an illustration, with the forward-looking statements notice '
          'on every slide and in the PDF.', label='Good to know')

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
    g.para('When the insurer\'s email arrives, say so: "The insurer confirmed CC-7F3A on 2026-10-20". The card marks the car insured as To do\'s Insurer confirmed does, '
           'from the date of the email. A car is found by its name, its plate or its car code (CC- and four characters, on the car page and in the chat).')
    g.para(f'Messages: ask it to draft a message to a renter or an owner. It writes the text; press {B("Copy")}, open the conversation and send it yourself.')
    g.task('Offers, rentals and what is owed')
    g.steps([
        'Send an offer: "Send an offer for the Corolla to jane@example.com, Nov 2 10:00 to Nov 4 10:00, deposit in cash". A customer on file is found by name, email or phone; '
        'a new customer needs the full name, email, mobile and date of birth.',
        'The card shows everything before anything is made: the customer, the car, the dates, each price line, the HST, what is due at booking, the deposit, how the rental and the deposit are paid, and how the offer is sent. '
        f'It is priced exactly as {B("Send an offer")} prices it. Press {B("Confirm")} to make and send it, or {B("Cancel")}.',
        'Add a rental: "Add a rental of the Corolla for jane@example.com, Nov 2 10:00 to Nov 4 10:00, paid by e-Transfer ref CA123, deposit in cash, signed on paper". The card lists the price lines and the payments the same way. Amounts after tax are understood: "$270 after tax for the rental and $50 after tax for the Protection Plan", or "$320 total after tax" (the rental charge is worked out so the total is exactly $320.00).',
        'Free cars: "Which cars are free from 2026-11-02 to 2026-11-04?" lists every bookable car with its rates, published or not.',
        'What is owed: "What does booking R-000123 owe?" or "What does Jane Doe owe?" shows the rental, fees and later charges still open, and the deposit.',
        'A payment on a booking is recorded by part: "Record a $200 e-Transfer on booking R-000123 for the fees, ref CA124".',
        'A booking made or paid through the assistant says so in its history: "Offer made with the staff assistant by" and your name.',
    ])
    g.tip('The assistant keeps 70% of the day\'s free AI allowance for itself, so it works all day. When the whole allowance is used, it says how much was used and that it is back at midnight, Toronto time. '
          'Everything still works from the screens and pop-ups.')

    # ---------------------------------------------------------------- usage (0080)
    g.chapter('Usage and paid usage',
              'The plans CarmaCars runs on include a free allowance: AI, the website, image transformations, emails, the database and storage. '
              'When an allowance runs out, AI and photo features pause with a short message until it resets. Workers AI never runs into paid usage; for photos you are asked before anything is paid.',
              blurb='Included allowances, the 80% and used-up alerts, Workers AI by feature (never paid), allowing paid usage for photos, what pauses and what never does.')
    g.task('The alerts', f'At 80% of an allowance you get one quiet card on {B("To do")} and one email to the alert address. When it is used up, a second card and email.')
    g.steps([
        'Workers AI used up shows "Stopped for today, never paid": it starts again at midnight, Toronto time. There is nothing to allow.',
        f'A used-up image allowance shows "Included ... used up for this month: Allow paid usage". Press {B("Allow paid usage")} to see what continuing costs at the current rates.',
        'Choose until the end of today or this month, type the most it may cost (for example $1), and press the Allow button. Or press Keep paused.',
        'Nobody answering keeps it paused: nothing is charged. Live chat goes to a person, AI copy waits with the template text, Turo emails are read by the rules, photos keep their original background, the assistant rests.',
        'The website and the portals are never paused (that would stop bookings): their card shows the estimated cost, usually cents.',
    ])
    g.task('Settings > Usage', f'Open {B("Settings")}, then {B("Usage")}: every service, used against included, when it resets, paid usage and the last 30 days.')
    g.steps([
        'Workers AI by feature, at the top: the neurons each feature used today and in the last 7 days (the staff assistant, visitor chat, the phone line, search copy, listing copy, guide upkeep, Turo emails, the readers), '
        'and what each share has left now. Use Cloudflare counted beyond the app\'s own record shows as Unmetered.',
        'The day is shared in three: 70% is kept for the staff assistant; visitor chat, the phone line and the readers share the rest; background writing (search copy, listing copy, guide rewrites, Turo emails) gets 10%, '
        'and from 9 pm what is left of the day, less a small cushion for the assistant.',
        f'Press {B("Change the shares")} to change the assistant\'s reserve, the background share, the release hour or the cushion.',
        f'Press {B("Change the allowance")} after a plan change (for example a Supabase or Resend upgrade).',
        f'Supabase egress is not readable automatically: press {B("Enter a figure")} with the number from the Supabase dashboard.',
        'Emails cannot be paid on the free plan: when the daily or monthly count is used, booking, payment and sign-in emails still go first and the others wait. A banner on To do says so.',
    ])

    # ---------------------------------------------------------------- maintenance
    g.chapter('Maintenance and service',
              'Every real car has its service items: oil, tire rotation, brakes, tires, the seasonal swap, the safety inspection, '
              'the registration, battery, wipers, filters, alignment, fluids and the annual inspection. Record a service once and '
              'the bill is made and the timers reset by themselves.',
              blurb='The fleet overview, recording a service and its bill, tires and swaps, the odometer, intervals, reminders and blocks.')
    g.task('The fleet overview', f'Open {P("Cars", "Maintenance")}.')
    g.steps([
        'Every real car (sample cars are left out), most urgent first: overdue, then due soon, then cars with no record yet, then all OK.',
        'Each car shows what is due next, its odometer, its km a day, the tires on it and the date of its last service.',
        'Use Show, Service item, Sort and the search (car, plate or owner) to narrow the list, then press Apply.',
        f'Press {B("Record a service")} on a car to record it without leaving the list.',
    ])
    g.table([
        ['Overdue', 'Past its km or its date (whichever came first), or expired'],
        ['Due soon', 'Within 1,000 km or 14 days of it (each item may have its own; inspections and registration: 30 days)'],
        ['Unknown', 'No record yet: record the last time it was done'],
        ['OK', 'Done, and not due soon'],
    ], head=['Status', 'Means'])
    g.task('Record a service in one step', f'From the overview, the car\'s {B("Maintenance")} tab, or a To do line.')
    g.steps([
        'Tick what was done. The items due are ticked already.',
        'Check the date and the odometer (filled with the current reading). Type the shop, the cost before HST and the HST (worked out at 13%, change it to match the receipt).',
        'Who pays: the owner (deducted on the owner\'s next statement, owner agreement 11.1; the default for an owner\'s car), CarmaCars (a company expense; the default for a company car), a claim (a repair cost on the claim), the renter (a charge at cost on the rental), or no charge.',
        f'Leave {B("The bill is in: bill it now")} ticked to make the bill now, or untick it and press {B("Bill now")} on the record when the bill comes in. Add the receipt.',
        f'Press {B("Record the service")}. Each item done is OK again, with its next date and km.',
    ])
    g.bullets([
        'An inspection or the registration: type the new expiry date, or leave it empty for 12 months from the service.',
        'Tires: type the tread depth measured, or tick New tires put on (the old set is retired as replaced).',
        'Seasonal swap: choose the set that went on and where the removed set is stored.',
        'An expense entered under Money, Expenses with a car and a service category (Car service: oil change, brakes, and so on) records the service too. Voiding either voids the other.',
        f'{B("Void")} on a record sets the timers back. A company expense is voided and an open owner cost is waived; a cost already on a statement or a claim stays, and the void is refused with what to do.',
    ])
    g.task('Tires and the seasonal swap', f'On the car\'s {B("Maintenance")} tab, under Tires.')
    g.steps([
        f'{B("Add a tire set")}: kind (summer, all-season, winter or all-weather), size, brand, tread depth, made (DOT) and bought dates, where it is stored, and whether it is on the car.',
        f'{B("Put on the car")} swaps sets and keeps the swap in the history.',
        'Tires are due soon at 4 mm of tread or 5.5 years old, overdue at 3 mm or 6 years.',
        'The swap follows Ontario: winter tires on by December 1 (reminder from November 1), off after April 1 (reminder from April 1, overdue after May 1). All-weather tires need no swap.',
    ])
    g.tip('The Winter tires add-on is offered only on cars with a winter set (on the car or stored), or with no tire record yet. A car on winter tires says so on the add-on.')
    g.task('The odometer')
    g.bullets([
        'The current odometer is the highest reading from handover and return reports, field staff moves, the rental\'s odometer out and in, listing photos, the car record, services and readings added by hand.',
        'Km a day comes from the readings of the last 90 days (else the rentals, else 60 km a day). It gives the date a km interval will be reached.',
        f'{B("Add a reading")} on the car; a reading lower than the last one needs the tick. An Admin can void a wrong reading.',
    ])
    g.task('Intervals, reminders and blocks', f'Open {P("Settings", "Maintenance")}.')
    g.bullets([
        f'Each item\'s default interval: {B("Change")}. Whichever of km and months comes first is due; 0 or empty means not by that measure.',
        f'{B("Add an interval")} for a class or one car. A car\'s own comes first, then its class\'s, then the default. On the car\'s tab, {B("Set an interval for this car")} does the same.',
        'Which expense categories are a service, and the items each records.',
        'Reminders: one Fleet task per car with what is due, To do lines (cars due, services to bill, cars with no record yet) and one line in the morning digest. No other email.',
        'Handover is refused while a recorded safety inspection or registration has expired. Block new bookings when overdue is off for every item until you turn it on.',
    ])
    g.para('Cars that were in the fleet before maintenance came in start as unknown, with one task each to record the last service. Enter what you know once.')

    # ---------------------------------------------------------------- email
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
        'A failed backup, or none for 30 hours, opens a site alert: an email (outside the quiet hours), a task and a line on To do. Tell your developer the same day.',
        'Keep a copy of the backup key in the company password manager. Without it no backup can be read.',
    ])

    g.task('Site health and alerts', f'{P("Today", "To do")}, the Site health card at the bottom.')
    g.steps([
        'Every 5 minutes the site checks itself: the home page, a car page, the sign-in page and the site\'s health check, and also emails, scheduled jobs, the nightly backup and Stripe payments.',
        'Each line shows Working, Problem, Waiting for the website deploy or Not checked yet, what was found and how many checks failed in the last 24 hours.',
        'Short problems, such as a single Error 1102, only show here and in your morning digest ("Site check: 6 failed checks in the last 24 hours, no alert email").',
        'An email goes to rent@carmacars.ca only for a real outage: a page failing every check for 15 minutes, emails failing for 30 minutes, the nightly backup failing, or Stripe failing for 30 minutes. It also raises an urgent task and "Site problems found by the site check" first on To do. A failed scheduled job is never emailed.',
        'At most 3 alert emails a day, and none from 11 pm to 7 am unless the whole site has been down for an hour. An outage held overnight is emailed at 7 am if it lasts. One "Recovered" email follows each alert, and the task closes by itself.',
        '"Waiting for the website deploy" on the health check means the database was updated before the website: nothing is wrong, and it turns to Working after the deploy.',
    ])
    g.tip('The alert address, the minutes before an email, the daily limit and the quiet hours are in Program settings, "Site check".', label='Good to know')

    g.task('When a page shows "Error 1102"')
    g.para('Our web host\'s free plan sometimes stops a page that takes too long. Reload the page; you are still signed in. '
           'Moving to the Workers Paid plan removes it.')

    g.reference(
        nav_rows=[('To do', 'What needs you now, most urgent first'),
                  ('Search', 'Any booking, plate, VIN, name or email'),
                  ('Bookings', 'Requests, bookings, the calendar, adding a rental'),
                  ('Cars', 'Vehicles, listings, calendar sync, sample photos'),
                  ('Money', 'Owner invoices and debits, payments, statements, tolls'),
                  ('People', 'Applications, owners, partners, owner forms; renters, staff, investors, View as'),
                  ('Marketing', 'Ad text for each channel, posted ads, social drafts, bookings by channel, owner recruitment'),
                  ('Settings', 'Site, program, forms, guides, emails, audit log')],
        top_tasks=[('Answer an application', f'{P("People", "Applications")}, then {B("Approve")}, {B("Ask for something")} or {B("Decline")}'),
                   ('Send an offer', f'{P("Bookings", "Requests")}, the booking, then {B("Send the offer")}'),
                   ('Change a booking', f'The booking\'s Changes tab, then {B("Send to the renter")}'),
                   ('Publish a car', f'To do, the car\'s line, then {B("Set rates and publish")}'),
                   ('Mark a car insured', f'To do, the car\'s line, then {B("Mark insured")}'),
                   ('Check renter documents', f'To do, the booking\'s line, then {B("Review documents")}'),
                   ('Let someone in', f'{P("People", "Portals and view as")}, then {B("Invite")}'),
                   ('Help someone sign in', f'{B("Send password link")}'),
                   ('Read a toll notice', f'{P("Money", "Tolls and tickets")}, then {B("Read a notice")}'),
                   ('Monthly statements', f'{B("Build all for a month")}, Approve, Issue')],
        extra_problems=[('You can\'t change anything', 'You are viewing as someone. Press Exit on the red banner.'),
                        ('Asked for a 6-digit code', 'Open your authenticator app. Lost phone: remove the factor in the Supabase dashboard.')])
    return g
