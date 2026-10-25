from lib import Guide, S, B, P, U


def build():
    g = Guide(
        key='investor', title='Investor Portal Guide', short='Investor',
        promise='Your investment, your returns and your statements, any time.',
        cover_shot=S('investor/01-investments-phone', 0, 595, 390, 1350),
        audience='investors', signin_url='carmacars.ca/sign-in?next=/investor', lands_on='Investments')

    g.start_page(
        who='Investors with an Investment Agreement with CarmaCars. Your portal shows each investment, what it has earned '
            'and paid, your monthly statements, and lets you send notices to us.',
        need=['The invitation email from CarmaCars (investor accounts are by invitation only)',
              'Access to that inbox: the link works for 24 hours, once',
              'An authenticator app, if you choose two-step sign-in (recommended)'],
        first_steps=[
            f'Open the invitation email and press its link within 24 hours.',
            f'Choose a password of 8 characters or more and press {B("Save the new password")}. You land on Investments.',
            f'Next time, sign in at {U("carmacars.ca/sign-in")}, or use Investor sign in at the bottom of any page of carmacars.ca.',
            f'Forgot your password? Press {B("Forgot your password?")} on the sign-in page.',
        ],
        shot=S('public/09-sign-in-phone', 0, 595, 390, 1180, pins=[(3, 372, 1041)]),
        note=f'Link expired? The page it opens has {B("Send me a new link")}.')

    g.chapter('Your investments',
              'Investments shows each of your investments: what you put in, what it earns, and when it pays.',
              blurb='Each investment, its returns and the latest statement.')
    g.task('Read an investment')
    g.steps([
        f'The tabs: {B("Investments")}, {B("Statements")}, {B("Documents to sign")}, {B("Investor deck")} (while CarmaCars shares it) and {B("Profile and notices")}. {B("Guide")} and {B("Sign out")} are at the top.',
        'Your agreement number and name, your Invested Amount, the Returns paid to date (or reinvested) and the next payment, with a chart of your account month by month.',
        'Each investment: its Invested Amount, how far the lockup period has run, the Yearly Percentage, how Returns are handled (Paid monthly or Reinvested) and the Next Payment Date. Principal, what was reinvested and redeemed to date, the Investment Date and the Lockup End Date are under "Principal, dates and amounts to date".',
        'Payment schedule: the last Returns on your statements and the next ones. An amount that is not on a statement yet is marked Estimated.',
        f'Latest statement, with {B("Open")}.',
    ], shot=S('investor/01-investments-phone', 0, 595, 390, 2140, pins=[(1, 100, 780), (2, 150, 1095), (3, 200, 1700), (5, 200, 2060)]))
    g.tip('This area shows your records under your Investment Agreement. It is not an offer or a solicitation.')

    g.task('Sign your investment agreement', 'When CarmaCars sends your agreement, it is under Documents to sign.')
    g.steps([
        f'Press {B("Documents to sign")} in the menu. The top shows what is signed ("0 of 1 signed").',
        'Check the key values: your name and address, the Invested Amount, the Yearly Percentage and the dates. The agreement is filled in from your record.',
        f'Press {B("Read the PDF")} and read it, with its schedules.',
        'Say whether you got independent legal advice, and tick the risk acknowledgment (Schedule C). Your initials are filled in.',
        f'Press {B("Sign")}. Your full legal name is your signature (or press {B("Draw instead")}). The signed copy is on the same page.',
    ])
    g.para('Once you sign, the agreement shows "Awaiting countersignature by CarmaCars" under Signed. CarmaCars\'s signing officer countersigns it; '
           'the agreement binds CarmaCars once it is countersigned and your funds have cleared. You get the countersigned copy on the same page.')
    g.tip('Signed on paper instead? Once we record it, it shows under Signed with the scan.')

    g.chapter('How your returns work',
              'Your return is worked out month by month on the Invested Amount, at the Yearly Percentage in your agreement. '
              'Here is the cycle and the words your statements use.',
              blurb='The monthly cycle, the terms on your statements, notices and holds.')
    g.task('The monthly cycle')
    g.flow([('Return Month', 'Your Invested Amount earns for each day of the month'),
            ('Statement', 'The return is worked out after the month ends'),
            ('The 15th', 'Paid to your bank account, or reinvested'),
            ('Email', 'Your statement, with its PDF attached')])
    g.bullets([
        'No return is earned for the lockup period. Your first Return Month starts on your Lockup End Date.',
        'Paid monthly: the return is paid by bank transfer on the 15th of the month after the Return Month (the Next Payment Date).',
        'Reinvested: the return is added to your Invested Amount, so it earns from then on.',
        'Each statement shows the Invested Amount at the start and the end of the month, so you can follow it over time.',
    ])
    g.task('The words on your statements')
    g.table([
        ['Invested Amount', 'What is earning a return: your principal, plus returns reinvested, less amounts redeemed.'],
        ['Principal', 'What you invested.'],
        ['Yearly Percentage', 'The yearly rate in your agreement.'],
        ['Investment Date', 'The day your funds cleared.'],
        ['Lockup End Date', 'Six months after the Investment Date. No return is earned before it.'],
        ['Return Month', 'The calendar month a return is earned in.'],
        ['Days earning', 'How many days of the month the amount earned, for example 31 of 31.'],
        ['Next Payment Date', 'When the next return is paid: the 15th of the month after the Return Month.'],
    ], head=['Term', 'What it means'])
    g.task('Notices from CarmaCars')
    g.para('Two notices can appear on Investments, under Needs your attention, above your investments:')
    g.table([
        ['Return on hold:', 'A return is held, with the reason, for example tax information we still need. Send what it asks for and we release it.'],
        ['Redemption notice:', 'CarmaCars will repay an amount, with the Redemption Date.'],
    ], head=['Notice', 'What it means'])
    g.task('Emails you get from us')
    g.bullets([
        'Your statement is ready, with the PDF attached, each month.',
        'Your return was paid, with the amount and date (not sent when it is reinvested).',
        'We received your notice: an election change, a bank account change or a contact change.',
    ])
    g.tip('Our investor emails are servicing notices about your existing investment. They are not an offer or a solicitation. '
          'CarmaCars gives no tax advice.')
    g.task('Texts or email', f'On {B("Profile and notices")}, under {B("Messages")}, choose {B("Email")}, {B("Text")} or {B("Both")}. Texts need a phone you verified with a code and link to the page. Statements are always emailed. Reply STOP to any text to stop them.')

    # ---------------------------------------------------------------- the investor deck (0083)
    g.chapter('The investor deck',
              'The investor deck tells the CarmaCars story in slides: the problem we solve, how the business makes money, every feature of the platform '
              'with its real screen, the investment offer, its risks, and how your Return builds.',
              blurb='What CarmaCars built, how it makes money, and a calculator for your Return.')
    g.task('Open the deck')
    g.steps([
        f'On {B("Investments")}, press {B("Open the deck")}, or press {B("Investor deck")} in the menu.',
        f'Above the slides, {B("Watch the deck")} plays the whole deck, narrated, in a few minutes, with captions in the player (it is there once CarmaCars has published the video).',
        f'Move with {B("Previous")} and {B("Next")}, the arrow keys, or a swipe left or right on a phone. The list at the top jumps to any slide.',
        f'Press {B("Download PDF")} to save or print it: each slide prints on its own landscape page.',
    ])
    g.task('The calculator')
    g.steps([
        f'Enter an amount (at least the minimum investment) and choose {B("Paid monthly")}, {B("Reinvested")} or {B("Reinvest, then paid")}.',
        'Choose how many years to show and the Investment Date.',
        'You see when the lockup ends, your first payment date, what a full month pays, what is paid to you for the period, and your Invested Amount at the end, with a chart and a month-by-month table.',
    ])
    g.para('The calculator follows your agreement exactly: no Return for the lockup, then one twelfth of the Yearly Percentage on the Invested Amount each month, '
           'by days for a part month, paid on the 15th of the next month or added to the Invested Amount at month end.')
    g.tip('The examples use the yearly percentage of our current offer. Your own percentage is the one in your agreement. Every example and figure in the deck '
          'is an illustration, not a forecast or a promise, and is not part of any offering memorandum.', label='Good to know')

    g.chapter('Statements',
              'One statement per month, as a page and a PDF. We also email each statement with its PDF attached.',
              blurb='Monthly statements, PDFs and yearly downloads.')
    g.task('Open a statement')
    g.steps([
        'Statements lists each Return Month with the Invested Amount, days, the return and whether it was paid or reinvested.',
        f'Press a month to open it, or {B("PDF")} beside it.',
        'Download a year: all statements of a year (ZIP) and the summary table (CSV). Yearly summaries come as PDF.',
    ], shot=S('investor/02-statements-phone', 0, 640, 390, 1300, pins=[(1, 365, 1090), (2, 135, 1022)]))
    g.steps([
        f'A statement shows the investor, the agreement, the amount at the start of the month, the Yearly Percentage, the days earning, the return for the month, when it is paid, and the amount at the end. Press {B("Download PDF")} to keep it.',
    ], shot=S('investor/03-statement-phone', 0, 640, 390, 1300, pins=[(4, 325, 955)]))

    g.chapter('Profile and notices',
              'Your contact details, and the notices you can send us: how returns are handled, your bank account, '
              'and a transfer request.',
              blurb='Contact details, notices about returns and bank account, transfers, two-step sign-in.')
    g.task('Contact details')
    g.para('Contact details shows your name, email, phone, address and bank account on file. To update these, ask us; we confirm by phone.')
    g.task('Change how returns are handled')
    g.steps([
        'Under How returns are handled, choose Paid monthly or Reinvested.',
        f'Press {B("Send the notice")}. The change applies from the first Return Month that starts at least 10 days after we receive it.',
    ], shot=S('investor/04-profile-phone', 0, 1940, 390, 2110, hdr=False))
    g.task('Bank account and transfers')
    g.steps([
        f'To change the account we pay, press {B("Ask to change the bank account")}. We call you at the number on file to take the new details. A change applies 10 days after notice.',
        f'To transfer an investment, choose it, fill in To (full name) and a Note, then press {B("Send the request")}. A transfer needs CarmaCars\' written consent.',
        'You see "Received. CarmaCars will confirm in writing." We confirm each request by email.',
    ])
    g.task('Two-step sign-in (recommended)')
    g.steps([
        f'At the bottom of Profile and notices, press {B("Set up two-step sign-in")}.',
        'Scan the code with your authenticator app.',
        f'Type the 6 digits and press {B("Continue")}. From then on, every sign-in asks for a code.',
    ])
    g.para('Documents, further down the same page, lists your statements as files.')

    g.chapter('Keeping your account safe',
              'Your portal holds your investment records. A few habits keep it yours.',
              blurb='Signing out, email links, two-step sign-in and the wrong account.')
    g.task('Good habits')
    g.table([
        ['Sign out on shared computers', f'{B("Sign out")} is at the top of every page. It signs you out on this device only.'],
        ['Email links work once', 'Invitation and password links work for 24 hours, once. Never forward them.'],
        ['Two-step sign-in', 'With it on, a password alone cannot open your portal. Set it up under Profile and notices.'],
        ['We never ask for your password', 'CarmaCars never asks for your password or a sign-in code by email or phone.'],
        ['Bank changes are confirmed by phone', 'We call the number on file before we change where returns are paid.'],
    ], head=['Habit', 'Why'])
    g.task('Signed in with the wrong account?')
    g.para('If a page says "You are signed in as ..." and that you have no access, you are signed in with another '
           f'CarmaCars account (for example a renter account). Press {B("Sign out")}, then sign in with the email your invitation was sent to.')

    g.reference(
        nav_rows=[('Investments', 'Each investment, returns, next payment'),
                  ('Statements', 'One per month; PDF, ZIP and CSV by year'),
                  ('Profile and notices', 'Contact details, notices, transfers, two-step sign-in')],
        top_tasks=[('See what you earned', f'{B("Statements")}, then a month'),
                   ('Keep a statement', f'{B("Download PDF")}'),
                   ('A whole year', f'{P("Statements", "Download a year")}'),
                   ('Paid monthly or reinvested', f'{B("Send the notice")}'),
                   ('Change your bank account', f'{B("Ask to change the bank account")}'),
                   ('Transfer an investment', f'{B("Send the request")}'),
                   ('Protect your account', f'{B("Set up two-step sign-in")}')],
        extra_problems=[('Asked for a 6-digit code', 'Open your authenticator app. Lost your phone? Call us.')])
    return g
