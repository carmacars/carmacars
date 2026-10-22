from lib import Guide, S, B, P, U


def build():
    g = Guide(
        key='owner', title='Owner Portal Guide', short='Owner',
        promise='Your cars, your money and your paperwork, in one place.',
        cover_shot=S('owner/03-vehicle-phone', 0, 595, 390, 1350),
        audience='owners', signin_url='carmacars.ca/sign-in?next=/owner', lands_on='Home in your owner portal')

    g.start_page(
        who='Owners who list one or more cars with CarmaCars, whether Managed, Self-managed or Turo only. '
            'Your portal shows each car, its bookings, your invoices, statements and payouts, and every form to sign.',
        need=['The email address you applied or were invited with',
              'Each car\'s VIN, ownership permit and insurance details',
              'A Canadian bank account for your fees and payouts'],
        first_steps=[
            f'New to CarmaCars? Apply at {U("carmacars.ca/list-your-car")}. Your account is made at the end of the application: open the email "Confirm your CarmaCars account" within 24 hours and its link opens your owner portal.',
            f'Invited by us? Open the invitation email within 24 hours, choose a password and press {B("Save the new password")}.',
            f'Next time, go to {U("carmacars.ca/sign-in")}, enter your Email and Password and press {B("Sign in")}.',
            f'Forgot your password? Press {B("Forgot your password?")} on the sign-in page and follow the email.',
        ],
        shot=S('public/09-sign-in-phone', 0, 595, 390, 1180, pins=[(3, 372, 1041)]),
        note='Email links work for 24 hours, once. If a link has expired, the page it opens has '
             f'{B("Send me a new link")}.')

    # ---------------------------------------------------------------- 1
    g.chapter('Apply and get your car listed',
              'You apply online in about ten minutes. We reply within one business day, set your terms, '
              'and walk you through the rest.',
              blurb='Apply online, sign, pay the upfront invoice and get your car on the site.')
    g.task('Apply to list your car')
    g.steps([
        f'Go to {U("carmacars.ca/list-your-car")} and press {B("Apply to list your car")}.',
        f'About you: individual or corporation, your address, licence and date of birth. Press {B("Continue to vehicles")}.',
        f'For each car, type the VIN: your car is found as you type the last character (Edit if anything is wrong), then tap its colour and answer the rest. Use {B("Add another vehicle")} for more cars.',
        f'Read how it will work, press {B("Continue")}, then {B("Review")}.',
        f'Press {B("Submit application")}, then {B("Go to your owner portal")}.',
    ], shot=S('public/13-list-your-car-desktop', 0, 0, 1440, 800, pins=[(1, 290, 599)]))
    g.tip(f'Need a break? {B("Email me a link")} saves your application and sends you a link to finish later.')
    g.tip(f'No car to add yet? On the vehicle step press {B("I\'ll add my car later")}, choose your password and press {B("Open my owner account")}. '
          f'Your owner portal opens with {B("Add your first car")}: press it when you are ready, starting with the VIN.', label='Good to know')
    g.task('What happens next', 'Five steps take your car from your driveway to its first rental.')
    g.flow([('Tell us about the car', 'We confirm fees and set your terms'), ('Sign the agreements', 'Online, one for all your cars'),
            ('One registry visit', 'We fill in the forms and come with you'), ('Tracker and insurance', 'We install it and add the car'),
            ('Photos and listing', 'Live within 1 business day')])
    g.steps([
        f'When your terms are ready, Home shows {B("Check and sign")}. Everything is filled in from your application: check the short list of key values (each has a {B("Fix")} link) and open any document to read it in full.',
        f'Tap {B("All of these")} for the three confirmations (your initials are filled in), then press {B("Sign all")}. Your name on file is your signature; prefer to draw it? Press {B("Draw instead")}. One signature covers every document, in about a minute.',
        'Pay the upfront invoice: the first and last month\'s insurance fee for each car (see chapter 4).',
        'Upload what each car\'s checklist asks for: the ownership permit, the lender\'s permission if it is financed or leased, and insurance.',
        'Sign Forms C and D (filled in for you) with witnesses: Form C on screen with your witness beside you, or on paper; Form D on paper, with a photo of each page from your phone (see chapter 5).',
    ])
    g.task('If we need a little more', 'Sometimes we need one more document before we can approve your application, for example the ownership permit or the insurance slip.')
    g.steps([
        'You get an email, and Home shows "We need a little more" with the list and any note from our team.',
        f'Upload what is asked, or write Your answer, and press {B("Send my answer")}.',
        'We review it within 1 business day. Once we approve your application, you get an email and Home shows Check and sign.',
    ])

    # ---------------------------------------------------------------- 2
    g.chapter('Home and your vehicles',
              'Home tells you what to do next. Each car has its own page with its status, terms, bookings, '
              'invoices and photos.',
              blurb='What Home shows, each car\'s page, adding a car and new listing photos.')
    g.task('Home at a glance')
    g.steps([
        'The menu: Home, Vehicles, Bookings, Invoices, Statements, Payouts, Documents, Banking, Notifications and Profile.',
        'Your vehicles: each car with its status and what it needs next.',
        'Money: what is due now, your fees each month, the next billing date and the next payout date.',
        f'Got another car? Press {B("Add a vehicle")}.',
    ], shot=S('owner/01-home-desktop', 0, 0, 1440, 760,
              pins=[(1, 470, 174), (2, 615, 400), (3, 1075, 380), (4, 560, 350)]))
    g.tip('When something needs you (a signature, a payment or an upload), it is the first thing on Home.')

    g.task('A car\'s page', 'Open Vehicles, then a car.')
    g.steps([
        'The top shows the car, its plate and how it is enrolled, with its status.',
        'Terms: the Insurance Fee, the Revenue Share, your enrolment date and a link to the listing.',
        f'Bookings shows every trip in your car. {B("Book it for myself")} reserves it for you.',
        'Leaving explains the exit notice and has the button to give it.',
    ], shot=S('owner/03-vehicle-desktop', 0, 230, 1440, 1450,
              pins=[(1, 690, 351), (2, 1057, 476), (3, 335, 1145), (4, 1180, 992)]))
    g.para('While a car is being set up, its page also shows the onboarding checklist and the uploads it still needs: '
           'the ownership permit, the lender\'s permission and the insurance.')

    g.task('Take new listing photos', 'Good photos get more bookings. You can shoot them yourself with your phone.')
    g.steps([
        f'On the car\'s page, press {B("Add listing photos")} (or {B("Take new photos")} for a car already live).',
        'Read the tips for each shot: daylight, a plain background, the phone held landscape.',
        f'Press {B("Take photo")} for each shot in the list. Press {B("Retake")} if one is not right.',
        'The bar shows how many required photos you have.',
        f'Press {B("Submit for listing")}. New photos replace the current ones once our team approves them.',
    ], shot=S('field/06-photo-shoot-capture-phone', 0, 1290, 390, 1900, hdr=False, pins=[(4, 360, 1555), (3, 300, 1718)]))

    # ---------------------------------------------------------------- 3
    g.chapter('Bookings and your own use',
              'See every booking in your cars on a calendar, and book a car for yourself when it is free.',
              blurb='The bookings calendar and booking your own car.')
    g.task('See your bookings')
    g.steps([
        'Bookings shows two months of your cars on a calendar. Each block is a booking number.',
        'All bookings lists every trip with its car, dates, amount and status.',
    ], shot=S('owner/04-calendar-desktop', 0, 280, 980, 1300, pins=[(1, 520, 380), (2, 120, 1240)]), fig_w=3.9)
    g.task('Book your own car', 'You pay no rental charge, fee or deposit. A renter\'s confirmed booking comes first.')
    g.steps([
        f'Open Bookings and use {B("Book my own car")} on the right (or {B("Book it for myself")} on the car\'s page).',
        'Choose the Vehicle, then the Pickup and Return date and time.',
        'Add a Note (optional) for our team.',
        f'Press {B("Book my car")}. You sign the same agreement a renter signs.',
    ], shot=S('owner/04-calendar-desktop', 990, 330, 1440, 900, pins=[(2, 1405, 413), (3, 1405, 700), (4, 1180, 841)]), fig_w=2.6)
    g.tip('No price and no deposit apply to you. One booking can be 30 days at most, and you sign the rental agreement before pickup.', label='Good to know')

    # ---------------------------------------------------------------- 4
    g.chapter('Fees, payments and payouts',
              'Your fees are debited from your bank account on the 15th, after a notice. Your payout for the month '
              'before arrives on the 10th, with a statement.',
              blurb='How fees are billed, the monthly debit, paying an invoice, statements and payouts.')
    g.task('How your fees work')
    g.bullets([
        'Each car has two monthly fees: an insurance fee and a tracker fee. They are due every month, rented or not.',
        'The tracker fee starts the day the car\'s tracker is installed. The tracker install fee has its own invoice.',
        'Before a car goes live you pay the first and last month amount we agreed with you (usually two months of the insurance fee, or the exact amount we agreed).',
        'Your amounts are the ones we agreed for each car, to the cent. Any other fee we agreed, for example a registration fee, comes on its own invoice with each line, its quantity and whether HST applies.',
        'One invoice per car. Registry, inspection and appraisal costs are not billed by us unless we agreed to pay them for you; then they are on an invoice of their own.',
    ])
    g.para('An invoice we cancel shows Void with the reason, and the invoice that replaces it. Nothing is debited for a void invoice. Every invoice has Download PDF.')
    g.task('The monthly debit, step by step')
    g.flow([('Notice day', '10 days before: your invoices and one email with the total'),
            ('The 15th', 'Each invoice is debited from your account'),
            ('Cleared', 'The invoice shows Paid and you get a receipt'),
            ('Insufficient funds?', 'A $50.00 Late Fee once, and the same amount tried again within 30 days')])
    g.bullets([
        'A debit is never more than its notice said. Each invoice shows "will be debited on" with the date.',
        'If your bank returns a debit for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.',
        'Returned for another reason (for example a closed account)? We do not try again and add no Late Fee. We pause your debit and email you: pay the invoice from its page, or set up a new account under Banking.',
        'Returned again after the retry? The invoice is in arrears and we contact you.',
        'You can always pay an invoice by card from its page before the debit day.',
        'On your bank statement the debit shows our company\'s legal name, operating as CarmaCars.',
    ])

    g.task('Set up the automatic debit', 'Do this once. Without it, we email you on each notice day to set it up.')
    g.steps([
        f'Open {B("Banking")}. Under Automatic debit of your fees, press {B("Set up pre-authorized debit")}.',
        f'Read the agreement and press {B("Continue to my bank details")}.',
        f'Enter your bank details and press {B("Save the bank account")}. Banking then shows the account and the next debit.',
    ], shot=S('owner/07-banking-desktop', 0, 280, 1440, 960, pins=[(1, 1385, 485)]))

    g.task('Pay an invoice now')
    g.steps([
        'Open Invoices, then the invoice. It lists what it covers and the balance.',
        f'Choose Card (paid at once) and press {B("Pay $...")}.',
        f'Or choose Pre-authorized debit (from a Canadian bank account, clears in 3 to 5 business days) and press {B("Authorize debit of $...")}.',
        'Prefer Interac e-Transfer? Send the amount to billing@carmacars.ca with the invoice number in the message.',
    ], shot=S('owner/06-invoice-desktop', 0, 330, 1440, 1000, pins=[(2, 100, 648), (3, 550, 648), (4, 165, 855)]))

    g.tip('Paid us by e-Transfer, cheque, cash or bank transfer? Once we record it, the invoice says "Paid by e-Transfer on" the date, you get a receipt by email, '
          'and the automatic debit does not take that amount. Paid part of it? The invoice shows Partly paid and only the rest is debited.')

    g.task('Tell us where to pay you')
    g.steps([
        f'Open {B("Banking")}. Under Where we pay you, choose Bank transfer or e-Transfer.',
        'Fill in Account holder, Institution number, Transit number and Account number (or your e-Transfer email).',
        f'Press {B("Submit payout details")}. For your security we confirm new details by phone before we use them.',
    ], shot=S('owner/07-banking-desktop', 0, 330, 990, 900, pins=[(1, 500, 423), (2, 900, 550), (3, 300, 834)]), fig_w=3.9)

    g.task('Statements and payouts')
    g.steps([
        'Statements: one a month, once approved by CarmaCars. Open one to see every booking, the revenue share, deductions and the payout.',
        f'Press {B("Download PDF")} to keep a copy. We also email it to you with the PDF attached.',
        'Payouts shows what was paid to you and when. Payouts are made on the 10th for the month before.',
    ], shot=S('owner/09-statement-desktop', 0, 280, 1440, 1000, pins=[(2, 230, 450), (1, 950, 532)]))

    # ---------------------------------------------------------------- 5
    g.chapter('Documents and forms',
              'Your signed agreements, uploads and government forms are under Documents. Some forms are '
              'filled for you; Forms C and D are signed with witnesses.',
              blurb='Agreements, government forms, Forms C and D, and official forms filled for you.')
    g.task('Sign everything at once',
           'Everything you sign on screen is in one place: Home shows how many are signed ("2 of 5 signed") and opens it with Check and sign.')
    g.steps([
        f'Press {B("Check and sign")} on Home (or open {U("carmacars.ca/owner/sign")}). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).',
        f'Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press {B("Fix")} next to it, change it, and come back.',
        'Open any document to read it word for word: the agreements, the schedules, Forms A and B, and the official registry forms that are ready.',
        f'Tap {B("All of these")} for the statements the agreement asks you to initial (your initials are filled in), then press {B("Sign all")}.',
        'Your name on file is your signature. One signature is applied to each document; CarmaCars countersigns at the same moment and every signed copy is in Documents.',
    ])
    g.tip('A car with a second owner on its ownership? Each owner named in the Title Schedule signs. The other owner gets their own link by email and signs the same documents on their phone or computer. '
          'The agreements take effect when the last owner signs; CarmaCars countersigns then.', label='Two owners')
    g.tip('Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.', label='Good to know')
    g.tip('Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.')

    g.task('We set up your car for you', 'When our team enters your car for you, you get one email: review the details and sign.')
    g.steps([
        'No sign-in yet? The email has a link to choose your password. It works once, for 24 hours; after that use Forgot password on the sign-in page.',
        f'Open {U("carmacars.ca/owner/review")} (Home has {B("Review or correct your details")}). Check your phone and address, and each car: plate, colour, odometer, your insurer and your lender. The terms we agreed are shown too.',
        f'Something wrong? Correct it and press {B("Save corrections")}. Your documents are filled in again and we are told. A term you did not agree to: message us before you sign.',
        f'Everything right? Press {B("Everything is right: sign")} and sign once.',
    ])
    g.task('Sign an updated Vehicle Schedule', 'When we agree new terms for a car you already signed for, you sign an updated Vehicle Schedule. Home shows it first.')
    g.steps([
        'Open it from Home or the email. It shows what changes (now and updated) and the date it applies from.',
        f'Read the text, tick that you agree, type your full legal name and press {B("Sign")}.',
        'Your current terms stay until you sign. After that, your invoices and statements use the new ones from the date.',
    ])

    g.task('Form C on screen, with your witness beside you',
           'Form C is the lender or lessor permission for a financed or leased car. It needs one witness, and you can sign it on screen when your witness is with you.')
    g.steps([
        'Open Documents. Under Forms to sign with witnesses, press Sign Form C on screen instead.',
        'Initial each of the three acknowledgments, and type Your initials.',
        'Sign: draw your signature in the box, or use your name.',
        f'Hand the device to your witness, another adult. They type their full name and tick the statement "I witnessed (your name) sign in my presence." Press {B("Sign Form C")}.',
    ], shot=S('owner/16-form-c-screen-desktop', 40, 1180, 830, 2160, hdr=False, pins=[(2, 85, 1313), (3, 300, 1720), (4, 90, 1986)]), fig_w=3.6)
    g.task('Forms C and D on paper, signed with witnesses',
           'Form D is a limited power of attorney (two witnesses), signed on paper. Form C can be signed on paper too, with one witness.')
    g.steps([
        f'Open Documents. Under Forms to sign with witnesses, press {B("Print the form")}. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.',
        'Sign it in front of your witnesses. They sign and print their names in their spots.',
        'Type each witness\'s full name in the boxes.',
        f'On your phone, press {B("Take a photo of the signed page")}: one photo of each page. A PDF scan works too ({B("Or choose a file")}).',
    ], shot=S('owner/12-forms-c-d-desktop', 0, 330, 1440, 1000, pins=[(1, 310, 499), (3, 1000, 634), (4, 1000, 706)]))
    g.tip('We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.')
    g.tip('Why paper for Form D? It is a power of attorney, which cannot be signed electronically in Ontario, and its two witnesses sign in person.', label='Good to know')

    g.task('Government forms filled for you',
           'Each car\'s registry forms are prepared from your records. Until we load the official PDF, you get a data sheet with the values.')
    g.steps([
        f'Open Documents and choose a form marked "Official form, filled for you".',
        f'Press {B("Download the filled form")} and check each value.',
        f'To sign it on screen, draw your signature in the box, then press {B("Sign and save")}. Forms ready to sign are also in the package on {B("Check and sign")}, signed with the same one signature. The signed copy is kept with your documents.',
    ], shot=S('owner/13-official-form-desktop', 0, 420, 1440, 1080, pins=[(2, 320, 564), (3, 720, 1047)]))
    g.warn('If the registry office asks for an ink signature, print the filled form and sign it there. You pay ServiceOntario, the inspection station and the appraiser directly.')

    # ---------------------------------------------------------------- 6b
    g.chapter('For partner rental companies',
              'A partner rental company uses this same portal. CarmaCars rents out your cars, keeps its commission and '
              'pays you the rest each month.',
              blurb='The partner portal, the partner agreement, statements and payouts.')
    g.task('Your partner portal')
    g.steps([
        'Home shows your partner number, our commission and your cars. CarmaCars adds your cars once we agree which ones join.',
        'Vehicles and Bookings show each car and its rentals. There are no program fees, so there is no Invoices page.',
        'Statements and Payouts: a statement for each month and the payment of your share.',
    ])
    g.task('Sign the partner agreement', f'Press {B("Check and sign")} on Home, or open {B("Partner agreement")}.')
    g.steps([
        'Check the key values at the top: who signs, your address, our commission, your insurance and your cars. The agreement is filled in from your partner record; open it to read it in full.',
        'Something wrong? Tell us before you sign and we fix it.',
        f'Press {B("Sign")}. Your name on file is your signature (or press {B("Draw instead")}). CarmaCars countersigns at once and the signed copy is in Documents.',
    ])
    g.tip('Your insurance covers your cars. We remind you before it expires: send us the new certificate and we record the new expiry.')
    g.tip('Prefer paper? Ask us for a copy, sign it and send us the scan. We record it and it counts the same.')

    # ---------------------------------------------------------------- 6
    g.chapter('Notices, profile and leaving',
              'Keep your details up to date, read our notices, and know how to take a car out of the program.',
              blurb='Notifications, your profile and giving an exit notice.')
    g.task('Notifications')
    g.steps([
        'Notifications lists our messages: new bookings, changes to a booking, payments and listing news.',
        f'Press {B("Mark as read")} on one, or {B("Mark all as read")}.',
    ], shot=S('owner/14-notifications-desktop', 0, 280, 1440, 900, pins=[(2, 290, 365)]))
    g.task('Your profile')
    g.steps([
        'Update your email, phone and address, then press Save.',
        'On your agreements shows your legal name and how you are enrolled. A change to these means new agreements, so call or message us.',
    ], shot=S('owner/15-profile-desktop', 0, 280, 1440, 1080, pins=[(1, 175, 947), (2, 1057, 393)]))

    g.task('Take a car out of the program', 'You give 30 days\' notice for that car only. Your other cars stay in.')
    g.steps([
        'Open Vehicles and the car. Read Leaving: when the notice ends and what happens to your last fees.',
        f'Press {B("Give notice")}. Add a Reason (optional).',
        f'Press {B("Give exit notice")}. The car\'s page then shows its exit date.',
    ])

    g.reference(
        nav_rows=[('Home', 'Next thing to do, your cars, money, next debit'),
                  ('Vehicles', 'Each car: terms, checklist, uploads, photos, Leaving'),
                  ('Bookings', 'Calendar, all bookings, Book my own car'),
                  ('Invoices', 'Fee invoices and Pay $...'),
                  ('Statements', 'One a month, Download PDF'),
                  ('Payouts', 'What was paid and when'),
                  ('Documents', 'Agreements, forms, Forms C and D'),
                  ('Banking', 'Automatic debit, where we pay you'),
                  ('Notifications', 'Our messages'),
                  ('Profile', 'Contact details, password')],
        top_tasks=[('Sign everything at once', f'{P("Home", "Check and sign")}'),
                   ('Set up the monthly debit', f'{P("Banking", "Set up pre-authorized debit")}'),
                   ('Pay an invoice now', f'{B("Invoices")}, the invoice, then {B("Pay $...")}'),
                   ('Payout details', f'{P("Banking", "Where we pay you")}'),
                   ('Forms C and D', f'{P("Documents", "Sign Form C on screen instead")} or {B("Take a photo of the signed page")}'),
                   ('Book your own car', f'{P("Bookings", "Book my own car")}'),
                   ('New listing photos', f'{B("Vehicles")}, the car, then {B("Take new photos")}'),
                   ('Leave the program', f'{B("Vehicles")}, the car, then {B("Give notice")}')],
        extra_problems=[('A debit was returned', 'You get an email with the reason. Insufficient funds: keep the money in the account for the retry, or pay the invoice from its page. Any other reason: pay from the invoice\'s page or set up a new account under Banking.')])
    return g
