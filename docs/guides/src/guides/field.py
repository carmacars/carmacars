from lib import Guide, S, B, P, U


def H(key, y1, pins=()):
    """A handover step, cropped to the step itself."""
    return S(f'field/{key}', 0, 1760, 390, 2110, hdr=False, pins=pins)   # the step starts below the job card; the screen is cut at 2110


def build():
    g = Guide(
        key='field', title='Field Portal Guide', short='Field',
        promise='Every handover, return and photo shoot, right on your phone.',
        cover_shot=S('field/29-handover-09-photos-phone', 0, 1760, 390, 2110),
        audience='field staff', signin_url='carmacars.ca/sign-in?next=/field', lands_on='My jobs, today\'s jobs in order')

    g.start_page(
        who='CarmaCars field staff: drivers, detailers, and drivers who also detail. You hand cars over, take them back, '
            'move them and shoot listing photos. Everything is on your phone.',
        need=['Your phone, charged, with a data connection (photos and signatures save as you take them)',
              'The invitation email from CarmaCars (the link works for 24 hours)',
              'A car charger and a cloth for the camera lens'],
        first_steps=[
            f'Open the invitation email on your phone and press its link within 24 hours. Choose a password and press {B("Save the new password")}.',
            f'You land on {B("My jobs")}. Next time, sign in at {U("carmacars.ca/sign-in")} with your Email and Password.',
            f'In your browser\'s menu, choose {B("Add to Home Screen")}. The portal then opens full screen, like an app.',
            f'Open {B("Profile")}, add your mobile number and press {B("Save my phone")}.',
            f'At the top of the page, fill in your Home address and Postal code and press {B("Save my home address")}. You need it before you add a rental or earn a commission.',
        ],
        shot=S('field/04-profile-phone', 0, 640, 390, 1500, pins=[(4, 360, 1300)]),
        note=f'Recommended: on Profile, press {B("Set up two-step sign-in")} and follow the steps with an authenticator app.')

    # ---------------------------------------------------------------- 1
    g.chapter('My jobs',
              'Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, '
              'the plate, the place and the time.',
              blurb='Your job list, a job card, maps and car moves.')
    g.task('Your job list')
    g.steps([
        f'The menu: {B("My jobs")}, {B("Report a problem")}, {B("My hours")}, {B("Add a rental")}, {B("My sales")}, {B("Referrals")} and {B("Profile")}. {B("Sign out")} is top right.',
        f'Switch between {B("Today")} and {B("Tomorrow")}. Jobs are in time order.',
        f'The next job is the big card at the top: its time and how long until it, the car and its plate, the place with {B("Open in maps")} and a button to call the renter, and what to put in the car. The rest of the day follows in time order.',
        f'A handover or a return has its own button: {B("Check out (pickup)")} or {B("Check in (return)")}. One tap acknowledges and starts the job and opens its photo checklist. Other jobs: press {B("Open the job")}.',
        'Moving a car that has no job? Use Vehicle moves (see below).',
    ], shot=S('field/01-today-phone', 0, 640, 390, 2110, pins=[(1, 355, 810), (2, 350, 1395), (3, 350, 1520), (4, 350, 1930)]))
    g.tip('Need help on a job? Call CarmaCars at 289-312-5991. The link is at the bottom of My jobs.')

    g.task('Open a job')
    g.steps([
        'The card shows the kind, the time, the car, the plate and colour.',
        f'The address, with {B("Open in maps")} for directions, and a button to call the renter.',
        'For a handover: the booking, the renter\'s name and phone, the Card on File and the licence on file.',
        f'Press {B("Acknowledge")} so the office knows you have it. Then press {B("Start")} when you are with the car.',
    ], shot=S('field/02-job-phone', 0, 640, 390, 2110, pins=[(1, 370, 1100), (2, 370, 1255), (3, 370, 1385), (4, 370, 2045)]))

    g.task('Check the renter\'s licence', 'The renter\'s licence photos and selfie are checked before the handover. You can check them yourself, for a booking on one of your own jobs today or in the next 7 days. Everything you do is recorded with your name and "field staff".')
    g.steps([
        f'My jobs shows {B("Licences to check")} when the licence front, back or selfie of a renter on one of your jobs waits for a decision. The same check is on the job itself, under {B("Check the licence")}.',
        f'Press {B("Review the licence")}. The images open with the name, date of birth and licence details on the booking.',
        'Look at each image: the name and date of birth match the booking, class G2 or G and valid past the return date with no sign of alteration, and the selfie matches the licence photo.',
        f'One is wrong? Open {B("Reject this one")} under it, type the reason the renter reads and press {B("Reject")}. The renter is told why and sends a new one.',
        f'Then press {B("Approve all")}: everything still waiting is approved at once.',
    ])
    g.tip('The renter\'s proof of coverage stays with the office. Meeting the renter at the handover? You can still check the original licence in person from the ready check (see A handover).')

    g.task('Move a car')
    g.steps([
        f'Under Vehicle moves, press {B("Start a move")}. Choose the Car and Why (for example Reposition).',
        f'Fill in From and the Odometer (km), then press {B("Start the move now")}.',
        f'When you arrive, press {B("End the move")}, fill in Now at and the odometer, then press {B("End the move now")}.',
    ])

    g.task('Documents to sign', 'Your staff agreement, when CarmaCars sends it.')
    g.steps([
        f'My jobs shows "You have a document to sign". Press {B("Read and sign")}.',
        f'Check the key values at the top (your role, wage and start date), then press {B("Read the PDF")} and read it.',
        f'Sign in a few steps: press {B("Send the code")} and type the 6-digit code from your phone or email, tick that you read it, draw your initials beside the key terms (confidentiality, the rules on money, keys and cars, ending the agreement), tick the two consents and draw your signature.',
        f'Press {B("Sign")}. The signed copy, with its certificate of completion, stays on the same page.',
    ])

    # ---------------------------------------------------------------- 2
    g.chapter('A handover',
              'You give the renter the keys only after every check passes. The steps guide you one by one: '
              'press Next after each, Back to go back.',
              blurb='The ready check, ID, card, odometer, photos, damage, signatures and the keys.')
    g.task('Before you start: the ready check', 'The first step lists what must be done before the car can go: signed, paid, ID checked, deposit.')
    g.steps([
        'Each line should show a green tick: agreement signed, identity verified, coverage confirmed, additional drivers accepted, the booking holds the calendar, deposit taken.',
        f'A red line shows what you can do about it right under it (see the next part). Fix it, then press {B("Check again")}.',
        f'All green? Press {B("Next")}.',
        f'Coverage or the calendar not ready? Only the office fixes those: call CarmaCars. Still not ready? Press {B("Stop: do not release the car")}.',
    ], shot=S('field/21-handover-01-ready-phone', 0, 1760, 390, 2110, pins=[(1, 355, 1960)]))
    g.warn('Never hand over keys if the ready check fails, the renter does not match the photo on file, or they do not have their '
           'original licence or the card on file. Stop and call us.')

    g.task('Fix the ready check on the spot', 'Most red lines are fixed on your phone, without calling the office. Everything you do is recorded with your name.')
    g.steps([
        f'Agreement not signed: press {B("Sign now on this device")} and hand the phone to the renter. Signed on paper instead? Open {B("Signed on paper instead? Scan it")}, take a photo of each page, then press {B("Record the signed paper copy")}.',
        f'Identity not verified: for each driver, press {B("Take")} for the licence front, the back and the selfie. Hold the original licence: tick that the name matches, the photo is the person, it is valid past the return and it is class G2 or G. No expiry on file? Type the licence number and the expiry. Press {B("The licence checks out")}.',
        f'Deposit not taken: press {B("Card hold: hand this phone to the renter")}. They type their card in Stripe\'s secure form; take the phone back and press {B("Back to the job")}.',
        f'Paid by e-Transfer instead: open {B("Paid by e-Transfer")}, type the reference number from their confirmation and press {B("Record the e-Transfer")}.',
        f'Paid in cash: open {B("Paid in cash")}, count the amount in front of the renter and press {B("I received")}. Keep the cash apart from your own money and hand it to CarmaCars within 1 business day, as Finance directs: Finance gets a task to collect it from you.',
        f'Additional driver not accepted: press {B("Sign now on this device (additional driver)")}.',
    ])
    g.tip('An expired licence, a face that does not match or a renter who will not sign: do not fix it. Press Stop and call us.')

    g.task('The steps, one by one')
    g.phones([
        (H('22-handover-02-car-ready-phone', 1480), f'Car ready: fuel full or charged 80%, clean, extras in. {B("Yes")} or {B("No")}, with a note for Fleet.'),
        (H('23-handover-03-renter-phone', 1420), 'Is this the renter? Compare the person with the name and photo on file.'),
        (H('24-handover-04-licence-phone', 1500), 'Original licence: name, photo and expiry match. A photo of a licence is not enough.'),
        (H('25-handover-05-card-phone', 1360), 'Card on File: you have seen the physical card with the same last four digits, in the renter\'s name.'),
        (H('26-handover-06-odometer-phone', 1360), 'Odometer: type the reading in km.'),
        (H('27-handover-07-fuel-phone', 1370), 'Fuel or charge: tap the level on the gauge, in eighths from E to F.'),
    ])
    g.phones([
        (H('28-handover-08-keys-phone', 1330), f'Keys: how many keys and fobs you hand over. Use {B("+")} and {B("−")}.'),
        (H('29-handover-09-photos-phone', 1500), f'Photo set: 19 photos in order. Press {B("Take this photo")} for the next one; every photo is also in the list below, with {B("Retake")} if needed.'),
        (H('30-handover-10-damage-phone', 1700), f'Damage: tap the car diagram where it is, choose Where and Type, then {B("Add the damage")}.'),
        (H('31-handover-11-tracker-phone', 1390), f'Tracker: it should say in place and reporting. {B("Check again")} if not. The car has to go anyway? Open {B("The car has to go anyway?")}, say why and press {B("Release without the tracker")}: an Admin is told at once.'),
        (H('32-handover-12-summary-phone', 1460), 'Renter reviews: the renter reads the summary of odometer, fuel, keys, photos and damage.'),
        (H('33-handover-13-signatures-phone', 1500), f'Signatures: the renter signs, then you. {B("Use this signature")} for each.'),
    ])
    g.steps([f'Press {B("Hand over the keys")}. You see "Checked out. The rental has started." The renter gets the photo report by email and in their Documents.'])
    g.tip('Photos wait on the phone without a connection and upload by themselves when it returns; the count shows what is still uploading. '
          'Each photo keeps its time, and the place when your phone allows location. No signal on a step? It says "Answers kept on this phone" and you can go on: '
          'press Try again, or they are sent when the signal returns.')

    g.task('Sign now on this device', 'The renter (or an additional driver) has not signed the rental agreement yet? They sign on your phone.')
    g.steps([
        f'On the job, press {B("Sign now on this device")}. It shows who still has to sign and whether their licence is on file.',
        f'Check the person: the name matches their licence, and you saw the original licence. Tick both. No licence on file? Press {B("Photograph: Licence, front")} (and the back and the selfie).',
        f'Press {B("Hand the device to")} and their name. They read the agreements (CarmaCars\' and Blind Spot\'s), tick the statements and sign with their name or their finger.',
        f'They hand the phone back: press {B("Back to the staff view")}. The signature record says it was signed in person, collected by you, on your phone.',
    ])
    g.task('The agreements at check-out', 'Both rental agreements follow the check-out.')
    g.steps([
        'Signing at pickup? Record the odometer and the fuel on the check-out first, then hand over the device: the agreement then shows the time, kilometres and fuel out, and the signed copy holds them.',
        'The signer gets a code on their phone, initials the key terms, ticks the consents and draws their signature.',
        'Already signed online? When you complete the check-out, the "as picked up" copy of both agreements is made with your readings and your countersignature, and emailed to the renter.',
        'The check-out stops if the agreement is missing something a claim needs (a licence expiry, a VIN). Ask the office to fill it on the booking, or an Admin to override.',
    ])
    g.task('The deposit on your phone', 'Deposit not taken yet? The ready check shows how to take it under the Deposit line. You never type a card number.')
    g.steps([
        f'Press {B("Card hold: hand this phone to the renter")}. They type their credit card in Stripe\'s secure form and press the button with the amount.',
        f'They see "Hold placed": take the phone back and press {B("Back to the job")}. The ready check shows the deposit taken.',
        f'A rental longer than the hold limit shows {B("Save the card on this phone (long rental)")} instead: Finance charges the deposit to that card.',
        'No credit card? When CarmaCars allows it, the renter pays the deposit by e-Transfer or in cash: record it under the Deposit line.',
    ])
    g.task('Add-ons to put in the car', 'A booking may come with add-ons: a baby seat, a child or booster seat, flowers, an umbrella, a phone charger or a prepaid full tank.')
    g.steps([
        'Open the job. Under Put in the car you see each add-on, how many, and what to do (for example "Put the bouquet on the front passenger seat").',
        'Put every item in the car before the handover. The Car ready step lists them again.',
        'Prepaid fuel: the renter may return the car at any fuel level. Do not charge for fuel at the return.',
        'A chauffeur on the booking: Fleet tells you who drives and when.',
    ])
    g.tip('An item missing? Write it in the note for Fleet on the Car ready step and call the office before the handover.')
    g.tip('The photo count shows "19 of 19 photos taken · all uploaded" when the set is complete. The first photo must show the plate. '
          'Open circles on the damage diagram were recorded before; add only what is new.')

    # ---------------------------------------------------------------- 3
    g.chapter('A return',
              'The return mirrors the handover. You record the car as it comes back and compare it with the pickup.',
              blurb='Odometer, fuel, keys, cleanliness, photos, new damage, belongings and signatures.')
    g.task('Take the car back')
    g.steps([
        'Car and keys received: confirm you have the car and its keys.',
        'Odometer, then Fuel or charge, as at pickup.',
        'Keys and extras: count what came back.',
        'Cleanliness: inside and out.',
        'Photo set: the same shots, in the same order, as at pickup.',
        f'Compare with pickup: for new damage, tap the diagram, fill in Where and What it is, press {B("Add the damage")} and take a close-up photo.',
        'Belongings: check the seats, the trunk, the glovebox and the door pockets.',
        'Renter reviews and signs. Then you sign.',
        f'Press {B("Complete the return")}. The check-in time is the moment you press it: a late return, the kilometres over the allowance and the fuel or charge used are charged from it automatically. The deposit is not given back at the return: Finance settles it once tolls and tickets have had time to come in (about 7 days), and new damage you mark keeps it held.',
        'The closing copy of both rental agreements follows by itself: time and date in, kilometres in, driven and charged, fuel in, the hours late, the new damage, the return charges and the totals, countersigned with your name, emailed to the renter.',
    ])
    g.warn('New damage needs a close-up photo and a clear note. Finance uses your photos and notes to bill the renter, so take your time.')

    # ---------------------------------------------------------------- 4
    g.chapter('Photo shoots',
              'A photo shoot job gets a car ready for its listing. You shoot the list of photos with your phone and submit them for review.',
              blurb='Shoot a listing\'s photos in order and submit them.')
    g.task('Shoot the listing photos')
    g.steps([
        f'Open the photo shoot job and read the tips: daylight, a plain background, the phone held landscape. Press {B("I have read this")}.',
        'The shot list: each photo with a short description. The bar shows how many required photos you have.',
        f'Press {B("Take photo")} for each shot (or {B("From photos")} to pick one you took). {B("Retake")} to redo one.',
        f'An upload failed? Press {B("Send again")}. Then press {B("Submit for listing")}.',
    ], shot=S('field/06-photo-shoot-capture-phone', 0, 1000, 390, 1730, hdr=False, pins=[(1, 350, 1250), (2, 350, 1495), (3, 113, 1710)]))
    g.tip('Keep other cars\' plates out of the frame. The reviewer covers this car\'s plate before the listing goes live.')

    # ---------------------------------------------------------------- 4b
    g.chapter('My hours and pay',
              'Clock in when you start and out when you finish. Your hours are paid every two weeks at your hourly rate (CA$18.00 an hour unless '
              'your agreement says another rate), with the commissions an Admin has approved, and you get a pay statement for each pay.',
              blurb='Clock in and out, your hours, and your pay statements.')
    g.task('Clock in and out')
    g.steps([
        f'Open {B("My hours")}. When you start work, add a note if you like (for example where you start) and press {B("Clock in")}.',
        'The big clock shows how long you have been on. The jobs you finish while clocked in are listed under it.',
        f'When you finish, press {B("Clock out")}. Add a note if you like. Your shift is saved with the time of each press.',
        f'Under {B("Recent shifts")} you see the last three weeks, each with its jobs. {B("This pay period so far")} shows your hours and what they come to at your rate.',
    ])
    g.warn('Forgot to clock out, or a time is wrong? You cannot change it yourself. Tell Fleet: they fix it, say why, and the change is written in a log. A shift left running more than 16 hours has to be fixed by Fleet or an Admin.')
    g.task('Your pay and your pay statements', 'A pay period is two weeks, Sunday to Saturday. An Admin runs the pay after it ends.')
    g.steps([
        'The pay is your hours times your hourly rate, plus the commissions and referral fees an Admin approved by the end of the period (see Commissions). Overtime and vacation pay are added only if CarmaCars has switched them on.',
        'An Admin approves the pay run, pays you (by e-Transfer, bank transfer or cash) and records it. You get an email with the amount and how you were paid.',
        f'Under {B("Pay statements")} on {B("My hours")}, press {B("PDF")} for the statement of a period: your hours day by day, the amounts, the commissions in it and how it was paid.',
    ])
    g.tip('A pay statement shows no income tax, CPP or EI. They are not worked out in the portal: for your tax slips, ask CarmaCars or your accountant.')

    # ---------------------------------------------------------------- 5
    g.chapter('Report, rentals, referrals and profile',
              'Report anything that happens on the road, add a rental for a renter you found, share your referral link, '
              'and keep your details up to date.',
              blurb='Report an incident, add a rental, commissions, your referral link and your profile.')
    g.task('Report a problem')
    g.steps([
        f'Open {B("Report a problem")} and choose the Car.',
        f'Choose What happened: {B("New damage found")}, {B("Warning light")}, {B("Collision while I was driving")}, {B("Ticket or toll while I was driving")}, {B("Lost property found")} or {B("Something else")}.',
        'Write the Details: where, when and what you see.',
        f'Press {B("Take a photo")} for each photo, then {B("Send the report")}.',
    ], shot=S('field/03-report-phone', 0, 640, 390, 1620, pins=[(1, 365, 1065), (2, 365, 1255), (3, 365, 1515)]))
    g.warn('In a collision, make sure everyone is safe and call 911 if anyone is hurt. Then call CarmaCars at 289-312-5991 before you send the report.')

    g.task('Add a rental for a renter you found', 'Your home address must be in your profile first: until it is, the page asks for it.')
    g.steps([
        f'Open {B("Add a rental")}. Choose the car, the dates and the places, then type the renter\'s details. A renter already on file is found by their email. Car already out with the renter? Enter the pickup as when it left: it is recorded as on trip.',
        f'Press {B("Check the calendar and the price")}. To charge another price, type it with the reason: a price far under the rate sheet is flagged for an Admin, not refused.',
        f'Choose {B("Send a payment link")} or {B("Charge the saved card when the renter signs")}. The renter pays online: you take no payment for it yourself.',
        f'Under Who found this client, choose {B("I sourced this client")} or {B("Entered for CarmaCars")}, then press {B("Add the rental")}.',
    ])
    g.task('Commissions')
    g.steps([
        'You earn 10% of the rental charge (before tax, after discounts, less refunds) of each rental you sourced: one you added and marked I sourced this client, or a booking made with your referral link.',
        'It is earned when the rental is completed and paid in full, then an Admin approves it and it is paid on your pay date. Your home address must be in your profile: until it is, a commission waits as not earned yet.',
        f'{B("My sales")} shows each commission: not earned yet, pending approval, approved, paid or reversed. A refund after payment comes off a later commission.',
    ])
    g.task('Referrals and profile')
    g.steps([
        f'{B("Referrals")}: your own referral link. Press {B("Copy the link")}, or let someone scan its QR code. A booking made with it counts as a rental you sourced.',
        f'{B("Profile")}: {B("Save my phone")}, your home address ({B("Change my home address")}), {B("Set up two-step sign-in")}, {B("Change my password")} and {B("Sign out")}.',
    ], shot=S('field/04-profile-phone', 0, 640, 390, 1500, pins=[(2, 360, 1300)]))
    g.task('Sign in with your phone number', 'Quicker on a phone than a password: a 6-digit code by text.')
    g.steps([
        f'On {B("Profile")}, under Sign-in, press {B("Add and verify my phone number")}, enter your mobile number and press {B("Text me a code")}.',
        f'Type the code from the text (it usually fills itself in) and press {B("Verify")}. Choose {B("My phone number (a code by text)")} under Sign in with.',
        f'Next time, the sign-in page opens on your phone number: press {B("Text me a code")} and enter the code. Two-step sign-in still asks for your authenticator code.',
    ])

    g.task('Texts or email', f'On {B("Profile")}, under {B("Messages")}, choose {B("Email")}, {B("Text")} or {B("Both")} for the messages we send you. Texts need the phone you verified above.')

    g.reference(
        nav_rows=[('My jobs', 'Today and Tomorrow, in order; Vehicle moves'),
                  ('A job', 'Open in maps, Acknowledge, Start'),
                  ('Report a problem', 'Damage, warning light, collision, ticket, lost property'),
                  ('My hours', 'Clock in and out, your shifts, your pay statements'),
                  ('Add a rental', 'A renter you found: a payment link or the saved card'),
                  ('My sales', 'Your rentals and commissions'),
                  ('Referrals', 'Your link and QR code'),
                  ('Profile', 'Phone, home address, two-step sign-in, password, Sign out')],
        top_tasks=[('Start a job', f'{B("Open the job")}, {B("Acknowledge")}, {B("Start")}'),
                   ('Hand over a car', f'Every step, then {B("Hand over the keys")}'),
                   ('Fix a red line', f'The buttons under the line, then {B("Check again")}'),
                   ('Stop a handover', f'{B("Stop: do not release the car")}, call us'),
                   ('Take a car back', f'Every step, then {B("Complete the return")}'),
                   ('Shoot listing photos', f'{B("Take photo")}, then {B("Submit for listing")}'),
                   ('Move a car', f'{B("Start a move")}, then {B("End the move")} and {B("End the move now")}'),
                   ('Report an incident', f'{P("Report a problem", "Send the report")}'),
                   ('Start and end work', f'{P("My hours", "Clock in")}, then {B("Clock out")}'),
                   ('Add a rental', f'{B("Add a rental")}, {B("I sourced this client")}, {B("Add the rental")}')],
        extra_problems=[('A photo did not upload', f'Check your signal, then press {B("Send again")}.'),
                        ('The renter does not match', 'Do not hand over. Press Stop and call us.')])
    return g
