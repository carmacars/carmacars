from lib import Guide, S, B, P, U


def H(key, y1, pins=()):
    """A handover step, cropped to the step itself."""
    return S(f'field/{key}', 0, 1095, 390, y1, hdr=False, pins=pins)


def build():
    g = Guide(
        key='field', title='Field Portal Guide', short='Field',
        promise='Every handover, return and photo shoot, right on your phone.',
        cover_shot=S('field/29-handover-09-photos-phone', 0, 595, 390, 1350),
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
        shot=S('field/04-profile-phone', 0, 595, 390, 1165, pins=[(4, 365, 1113)]),
        note=f'Recommended: on Profile, press {B("Set up two-step sign-in")} and follow the steps with an authenticator app.')

    # ---------------------------------------------------------------- 1
    g.chapter('My jobs',
              'Your day, in order: handovers, returns, deliveries, moves and photo shoots. Each job card has the car, '
              'the plate, the place and the time.',
              blurb='Your job list, a job card, maps and car moves.')
    g.task('Your job list')
    g.steps([
        f'The menu: {B("My jobs")}, {B("Report")}, {B("Add a rental")}, {B("My sales")}, {B("Referrals")} and {B("Profile")}. {B("Sign out")} is top right.',
        f'Switch between {B("Today")} and {B("Tomorrow")}. Jobs are in time order.',
        'Each card: the kind, the time, the status, the car and plate.',
        f'Press {B("Open the job")} to start.',
        'Moving a car that has no job? Use Vehicle moves (see below).',
    ], shot=S('field/01-today-phone', 0, 595, 390, 1480, pins=[(1, 30, 720), (2, 300, 795), (3, 350, 885), (4, 345, 975), (5, 300, 1067)]))
    g.tip('Need help on a job? Call CarmaCars at 647-575-3377. The link is at the bottom of My jobs.')

    g.task('Open a job')
    g.steps([
        'The card shows the kind, the time, the car, the plate and colour.',
        f'The address, with {B("Open in maps")} for directions.',
        'For a handover: the booking, the renter\'s name and phone, the Card on File and the licence on file.',
        f'Press {B("Acknowledge")} so the office knows you have it. Then press {B("Start")} when you are with the car.',
    ], shot=S('field/02-job-phone', 0, 595, 390, 1170, pins=[(1, 370, 860), (2, 370, 943), (3, 370, 1040), (4, 370, 1131)]))

    g.task('Move a car')
    g.steps([
        'Under Vehicle moves, choose the Car and Why (for example Reposition).',
        'Fill in From and the Odometer (km).',
        f'Press {B("Start a move")}. When you arrive, press {B("End the move")} and enter the odometer again.',
    ], shot=S('field/01-today-phone', 0, 1040, 390, 1490, hdr=False, pins=[(1, 340, 1140), (2, 340, 1312), (3, 340, 1460)]))

    g.task('Documents to sign', 'Your staff agreement, when CarmaCars sends it.')
    g.steps([
        f'My jobs shows "You have a document to sign". Press {B("Read and sign")}.',
        f'Check the key values at the top (your role, wage and start date), then press {B("Read the PDF")} and read it.',
        f'Press {B("Sign")}. Your full legal name is your signature (or press {B("Draw instead")}).',
    ])

    # ---------------------------------------------------------------- 2
    g.chapter('A handover',
              'You give the renter the keys only after every check passes. The steps guide you one by one: '
              'press Next after each, Back to go back.',
              blurb='The ready check, ID, card, odometer, photos, damage, signatures and the keys.')
    g.task('Before you start: the ready check', 'The first step lists what must be done before the car can go: signed, paid, ID checked, deposit.')
    g.steps([
        'Each line should show a green tick: identity verified, coverage confirmed, additional drivers accepted, the booking holds the calendar, deposit taken.',
        f'All green? Press {B("Next")}.',
        f'Anything not ready? Press {B("Stop: do not release the car")} and call the office.',
    ], shot=S('field/21-handover-01-ready-phone', 0, 595, 390, 1530, pins=[(1, 365, 1250), (2, 300, 1510)]))
    g.warn('Never hand over keys if the ready check fails, the renter does not match the photo on file, or they do not have their '
           'original licence or the card on file. Stop and call us.')

    g.task('The steps, one by one')
    g.phones([
        (H('22-handover-02-car-ready-phone', 1480), f'Car ready: fuel full or charged 80%, clean, extras in. {B("Yes")} or {B("No")}, with a note for Fleet.'),
        (H('23-handover-03-renter-phone', 1420), 'Is this the renter? Compare the person with the name and photo on file.'),
        (H('24-handover-04-licence-phone', 1500), 'Original licence: name, photo and expiry match. A photo of a licence is not enough.'),
        (H('25-handover-05-card-phone', 1360), 'Card on File: you have seen the physical card with the same last four digits, in the renter\'s name.'),
        (H('26-handover-06-odometer-phone', 1360), 'Odometer: type the reading in km.'),
        (H('27-handover-07-fuel-phone', 1370), 'Fuel or charge: slide to the level on the gauge.'),
    ])
    g.phones([
        (H('28-handover-08-keys-phone', 1330), f'Keys: how many keys and fobs you hand over. Use {B("+")} and {B("−")}.'),
        (H('29-handover-09-photos-phone', 1500), f'Photo set: 19 photos in order. {B("Take")} each one; {B("Retake")} if needed.'),
        (H('30-handover-10-damage-phone', 1700), f'Damage: tap the car diagram where it is, choose Where and Type, then {B("Add the damage")}.'),
        (H('31-handover-11-tracker-phone', 1390), f'Tracker: it should say in place and reporting. {B("Check again")} if not.'),
        (H('32-handover-12-summary-phone', 1460), 'Renter reviews: the renter reads the summary of odometer, fuel, keys, photos and damage.'),
        (H('33-handover-13-signatures-phone', 1500), f'Signatures: the renter signs, then you. {B("Use this signature")} for each.'),
    ])
    g.steps([f'Press {B("Hand over the keys")}. You see "Handed over. The rental has started."'])
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
        f'Press {B("Complete the return")}.',
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
    ], shot=S('field/06-photo-shoot-capture-phone', 0, 1000, 390, 1730, hdr=False, pins=[(1, 180, 1210), (2, 330, 1545), (3, 113, 1718)]))
    g.tip('Keep other cars\' plates out of the frame. The reviewer covers this car\'s plate before the listing goes live.')

    # ---------------------------------------------------------------- 5
    g.chapter('Report, rentals, referrals and profile',
              'Report anything that happens on the road, add a rental for a renter you found, share your referral link, '
              'and keep your details up to date.',
              blurb='Report an incident, add a rental, commissions, your referral link and your profile.')
    g.task('Report something')
    g.steps([
        f'Open {B("Report")} and choose the Car.',
        f'Choose What happened: {B("New damage found")}, {B("Warning light")}, {B("Collision while I was driving")}, {B("Ticket or toll while I was driving")}, {B("Lost property found")} or {B("Something else")}.',
        'Write the Details: where, when and what you see.',
        f'Press {B("Take a photo")} for each photo, then {B("Send the report")}.',
    ], shot=S('field/03-report-phone', 0, 595, 390, 1500, pins=[(1, 360, 820), (2, 360, 895), (3, 360, 1340), (4, 360, 1480)]))
    g.warn('In a collision, make sure everyone is safe and call 911 if anyone is hurt. Then call CarmaCars at 647-575-3377 before you send the report.')

    g.task('Add a rental for a renter you found', 'Your home address must be in your profile first: until it is, the page asks for it.')
    g.steps([
        f'Open {B("Add a rental")}. Choose the car, the dates and the places, then type the renter\'s details. A renter already on file is found by their email.',
        f'Press {B("Check the calendar and the price")}. To charge another price, type it with the reason: a price far under the rate sheet is flagged for an Admin, not refused.',
        f'Choose {B("Send a payment link")} or {B("Charge the saved card when the renter signs")}. You never take payment yourself.',
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
    ], shot=S('field/04-profile-phone', 0, 595, 390, 1440, pins=[(2, 365, 1113)]))

    g.reference(
        nav_rows=[('My jobs', 'Today and Tomorrow, in order; Vehicle moves'),
                  ('A job', 'Open in maps, Acknowledge, Start'),
                  ('Report', 'Damage, warning light, collision, ticket, lost property'),
                  ('Add a rental', 'A renter you found: a payment link or the saved card'),
                  ('My sales', 'Your rentals and commissions'),
                  ('Referrals', 'Your link and QR code'),
                  ('Profile', 'Phone, home address, two-step sign-in, password, Sign out')],
        top_tasks=[('Start a job', f'{B("Open the job")}, {B("Acknowledge")}, {B("Start")}'),
                   ('Hand over a car', f'Every step, then {B("Hand over the keys")}'),
                   ('Stop a handover', f'{B("Stop: do not release the car")}, call us'),
                   ('Take a car back', f'Every step, then {B("Complete the return")}'),
                   ('Shoot listing photos', f'{B("Take photo")}, then {B("Submit for listing")}'),
                   ('Move a car', f'{B("Start a move")}, then {B("End the move")}'),
                   ('Report an incident', f'{P("Report", "Send the report")}'),
                   ('Add a rental', f'{B("Add a rental")}, {B("I sourced this client")}, {B("Add the rental")}')],
        extra_problems=[('A photo did not upload', f'Check your signal, then press {B("Send again")}.'),
                        ('The renter does not match', 'Do not hand over. Press Stop and call us.')])
    return g
