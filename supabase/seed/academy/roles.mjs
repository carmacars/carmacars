// The sections of each staff function (Release 21b, item 9), from the Staff, Field and Admin guides (docs/guides/content).
import { S, title, chat, list, steps, money, rule, Q, L } from './helpers.mjs';

export const ROLE_SECTIONS = [
  // ---------------------------------------------------------------- customer service
  {
    slug: 'cs-requests', title: 'Answering requests and messages',
    blurb: 'Claiming a request, the five-minute reply, sending, changing or declining an offer, asking the renter, and the messages that follow.',
    lessons: [
      L('Claiming and the first reply',
        S('Requests come to you first', 'A request from the website goes to Admins, customer service and fleet first. Sales may take it after 15 minutes.', list('Who answers', ['Admins, customer service, fleet: at once', 'Sales: after 15 minutes'])),
        S('Opening a request holds it', 'When you open a request to answer it, it is yours for 20 minutes, renewed while you work. Others see "Being answered by" your name. It ends when you send, decline or leave.', rule('The claim', '20 minutes, renewed while you work. Answer or leave it.')),
        S('Reply within 5 minutes', 'Reply within 5 minutes in opening hours: send the offer, or ask the renter what you need. It is the first reply measure on your scorecard; requests waiting longer show in red.', title('5 minutes', 'Send the offer, or ask the renter')),
        S('Check before you offer', 'On the Review tab check the car is free, the renter, and the places. Adjust the booking if the car, dates, places, price or extras need to change.', steps('Answer a request', ['Open it from Requests', 'Review: car free, renter, places', 'Adjust the booking if needed', 'Add a message, Send the offer']))
      ),
      L('Offers, declines and changes',
        S('Within your limit', 'Within your limit you can also approve and send the pay link at once. Above it, an Admin approves.', rule('Your limit', 'Above it, an Admin approves.')),
        S('Declining well', 'Can\'t do it? Decline with the reason and an alternative: other dates, a similar free car.', chat(['you', 'The Corolla is booked those days. The Civic is free for your dates at the same price. Want me to send that offer?'])),
        S('Prices you type', 'You can type a total or a rate a day instead of the rate sheet, with a reason. A price far under the rate sheet is flagged for an Admin, never refused. Choose After tax when you type what the renter paid with HST.', list('Typed prices', ['Always give the reason', 'Far under the sheet: flagged for an Admin', 'After tax: HST included'])),
        S('A late return', 'A renter running late should ask to extend before the return time. Approve the extension if the car is free, and remind them to pay before the current return.', chat(['renter', 'I\'m stuck in traffic, 40 minutes late.'], ['you', 'Thanks for telling us. After a 30 minute grace it is $25 an hour. If you need longer, I can extend the booking now so it is not a late return.']))
      ),
      L('Renter messages and records',
        S('One renter, one record', 'Search before you add: by name, phone, email or booking number. Already on file? Use them, never a second record. Possible duplicates can be merged.', rule('Never a second record', 'Search first; merge duplicates.', 'warn')),
        S('Private details', 'To open a renter\'s private details, press Open with a reason. The reason is kept in the access log.', title('Open with a reason', 'Every opening is logged')),
        S('Marketing consent', 'Offer discounts and promotions only to renters who ticked marketing consent. Without it, talk only about their request.', rule('Consent', 'No offers without the marketing box ticked.', 'warn')),
        S('Reviews', 'Everyone gets the same review request and the same Google link. Never offer anything for a review and never ask only happy renters.', rule('Reviews', 'Same message to everyone; nothing offered for a review.', 'warn'))
      )
    ],
    quiz: [
      Q('How long does opening a request to answer it hold it for you?', ['5 minutes', '20 minutes, renewed while you work', 'Until the end of the day', 'Forever'], 1, 'The claim lasts 20 minutes and is renewed while you work.'),
      Q('What is the first reply target in opening hours?', ['5 minutes', '1 hour', '24 hours', 'No target'], 0, 'Reply within 5 minutes: send the offer, or ask the renter.'),
      Q('When may Sales take a new website request?', ['Never', 'At once', 'After 15 minutes', 'After an hour'], 2, 'Admins, customer service and fleet answer first; Sales may take it after 15 minutes.'),
      Q('You type a price far below the rate sheet. What happens?', ['It is refused', 'It is flagged for an Admin, with your reason', 'It is sent silently', 'The renter must approve twice'], 1, 'A typed price needs a reason; one far under the sheet is flagged, never refused.'),
      Q('A caller is already on file with that phone number. What do you do?', ['Make a new record', 'Use the existing record', 'Ask them for a new email', 'Ask an Admin'], 1, 'Never a second record: use the one on file, and merge duplicates.'),
      Q('A renter has not ticked marketing consent. Can you offer them a promotion?', ['Yes', 'No: talk only about their request', 'Only by text', 'Only with a code'], 1, 'Without marketing consent, offer nothing beyond their request.')
    ]
  },
  {
    slug: 'documents-and-signing', title: 'Documents, coverage proof and signing',
    blurb: 'Checking licences, selfies and coverage proof; e-signing on the spot or by link; paper signatures and new versions of the agreement.',
    lessons: [
      L('Checking documents',
        S('One screen for everything', 'Review shows every licence image, selfie and proof of coverage of the booking on one screen, with what to check written above them.', list('What to check', ['Name and date of birth match', 'Class G2 or G, valid past the return', 'The selfie matches the licence', 'Coverage active to the return date'])),
        S('Reject with a reason', 'If one is wrong, reject that one with a reason the renter reads, then approve the rest at once with Approve all.', steps('Review', ['Reject the wrong one, with the reason', 'Approve all for the rest'])),
        S('Coverage proof', 'OPCF 27 needs the page that shows it and an expiry after the return. Card coverage needs a credit card in the renter\'s name. The Protection Plan is confirmed by customer service.', rule('Coverage', 'Never approve proof that ends before the return date.', 'warn'))
      ),
      L('E-sign on the spot',
        S('Sign now on this device', 'On the booking, press Sign now on this device. Confirm the name and that you saw the original licence, then hand the device to the signer.', steps('Sign on the spot', ['Sign now on this device', 'Confirm the name and the original licence', 'Hand the device to the signer', 'Back to the staff view'])),
        S('What the signer does', 'Every signature has a code sent to the signer\'s phone or email, the key terms initialled, three consents and a drawn signature.', list('Every signature', ['A code to their phone or email', 'Initial the key terms', 'Three consents', 'A drawn signature'])),
        S('Or by link', 'Or press Email the signing link or Text the signing link, and they sign on their own phone.', title('Signing links', 'Email or text')),
        S('Changes make a new version', 'A change to the dates, price, car, drivers or coverage after signing makes a new version that waits for the renter\'s signature. Until they sign, the earlier version applies.', rule('New version', 'The renter signs again; the old version applies until then.'))
      ),
      L('Paper and the Blind Spot agreement',
        S('Signed on paper', 'Signed on paper? Record paper signature on the booking, check who signed and when, and upload every signed page.', steps('Paper signature', ['Record paper signature', 'Choose the agreement', 'Signed by and date', 'Upload every page'])),
        S('Two agreements', 'We rent under Blind Spot Car Rental\'s insurance, so each booking has a second agreement, Blind Spot\'s form, filled from the same booking. The renter signs both.', title('Two agreements', 'CarmaCars and Blind Spot, signed together')),
        S('Fields a claim needs', 'Check-out stops on a field a claim needs, like a licence expiry or a VIN, until it is filled or an Admin overrides. Fill the missing fields on the booking.', rule('Missing fields', 'Fill them before the handover.', 'warn'))
      )
    ],
    quiz: [
      Q('What must you confirm before handing your device to a signer?', ['Their email', 'Their name and that you saw the original licence', 'Their bank', 'Nothing'], 1, 'Confirm the name and that you saw the original licence.'),
      Q('The dates change after the renter signed. What happens?', ['Nothing', 'A new version waits for their signature; the earlier applies until then', 'The booking is cancelled', 'An Admin signs for them'], 1, 'A change makes a new version that the renter signs.'),
      Q('A licence is valid until the day before the return. What do you do?', ['Approve it', 'Reject it with the reason: it must be valid past the return', 'Ignore the date', 'Approve and tell the renter'], 1, 'The licence must be valid past the return date.'),
      Q('Why is there a Blind Spot agreement?', ['It is optional', 'We rent under Blind Spot Car Rental\'s insurance', 'For tolls', 'For owners'], 1, 'CarmaCars rents under Blind Spot\'s insurance, so its form is part of every rental.'),
      Q('What does every e-signature include?', ['Only a typed name', 'A code, initials on key terms, three consents and a drawn signature', 'A photo', 'A payment'], 1, 'Code, initials, consents and a drawn signature.')
    ]
  },
  {
    slug: 'insurer-billed-rentals', title: 'Insurer-billed rentals and adjusters',
    blurb: 'Insurance replacement rentals: Bill to the insurer, the claim and adjuster, the authorized days and rate, VLF, and emails from Blind Spot.',
    lessons: [
      L('Bill to the insurer',
        S('Insurance replacement', 'When a renter\'s own car is in for repair, their insurer often pays for a rental. The booking is billed to the insurer.', title('Insurance replacement', 'The insurer pays; the renter owes the rest')),
        S('Bill to', 'Choose Bill to: the renter, the insurer pays the rental and fees, or the insurer pays the rental only. With rental only, the renter pays the fees, add-ons and deposit.', list('Bill to', ['Renter: pays everything', 'Insurer: rental and fees', 'Insurer: rental only; renter pays the rest'])),
        S('The claim details', 'Record the insurer, the claim number, the adjuster\'s name, email and phone, the authorized days and the daily rate authorized, and the provisional end.', steps('Claim details', ['Insurer', 'Claim number', 'Adjuster: name, email, phone', 'Authorized days and daily rate', 'Provisional end'])),
        S('The authorized rate', 'The daily rate fills in from the insurer\'s rate sheet for the car. A rate you type that differs needs a reason. No rate on file? Type what the adjuster authorized.', rule('The rate', 'From the insurer\'s sheet; a different rate needs a reason.'))
      ),
      L('Adjusters and the insurer invoice',
        S('Emails from Blind Spot', 'Insurance emails go from Blind Spot Car Rental and replies come back there. Email the adjuster writes to the adjuster on the booking.', title('Email the adjuster', 'Always from Blind Spot Car Rental')),
        S('VLF and other insurer charges', 'The insurer invoice lists each charge as its own line, like the VLF, the vehicle licence fee, at a rate a day.', money('Insurer invoice', [['Rental, 5 days at the authorized rate', '$275.00'], ['VLF: 5 days at $5.00', '$25.00']])),
        S('Extending a claim', 'The adjuster may authorize more days. Update the authorized days and the provisional end, and keep the renter informed.', chat(['renter', 'My car is not ready yet.'], ['you', 'I will ask your adjuster to authorize more days and confirm with you. Until they approve, days past the authorized end are yours to pay.']))
      )
    ],
    quiz: [
      Q('Bill to "insurer pays the rental only". Who pays the fees and deposit?', ['The insurer', 'The renter', 'CarmaCars', 'Nobody'], 1, 'With rental only, the renter owes the fees, add-ons and deposit.'),
      Q('You type a daily rate that differs from the insurer\'s rate sheet. What is needed?', ['Nothing', 'A reason', 'The renter\'s signature', 'A new booking'], 1, 'A rate that differs from the insurer\'s sheet needs a reason.'),
      Q('Which sender is used to email an adjuster?', ['Your own email', 'CarmaCars', 'Blind Spot Car Rental', 'The owner'], 2, 'Email the adjuster always goes from Blind Spot Car Rental.'),
      Q('What is the VLF?', ['A late fee', 'The vehicle licence fee, a daily charge to the insurer', 'A fuel fee', 'A cleaning fee'], 1, 'VLF is a daily vehicle licence fee on the insurer invoice.'),
      Q('Which details must an insurer-billed booking carry?', ['Only the insurer', 'Insurer, claim number, adjuster, authorized days and rate', 'Only the claim number', 'The renter\'s bank'], 1, 'All of them: they go on every invoice and email.')
    ]
  },
  // ---------------------------------------------------------------- Sales (both modes)
  {
    slug: 'sales-requests-and-quotes', title: 'Sales: requests, quotes and offers',
    blurb: 'Taking requests after the wait, new quotes for callers, offers sent from a call, discount codes and leads from the website.',
    lessons: [
      L('Requests and quotes',
        S('When you may answer', 'Sales sees "Opens to you at" a time: a website request opens to you 15 minutes after it came in, with a Sales task when nobody is on it.', title('Opens to you at', '15 minutes after the request')),
        S('A new quote for a caller', 'New quote: choose the car, the pickup and return at least 2 hours from now, how the lead came in, the caller\'s legal name, email, mobile and date of birth, their licence class and damage cover.', steps('New quote', ['Car, pickup and return', 'How the lead came in', 'Legal name, email, mobile, date of birth', 'Licence class and damage cover', 'Create the request, then send the offer'])),
        S('Send an offer from a call', 'Find the customer or add them, choose the car, dates and places, the price, how it is paid, who found the client and how long it stays open, at most 48 hours.', list('Offer from a call', ['Customer: find or add', 'Car, dates, places', 'Price with reason if typed', 'Payment and deposit method', 'Open at most 48 hours'])),
        S('Example cars', 'An enquiry on an example car: never offer the example car itself, it does not exist. Offer a real free car of the same kind and price.', rule('Example cars', 'Never offer the example car. Offer a real one.', 'warn'))
      ),
      L('Closing the sale',
        S('Urgency without pressure', 'Be honest about urgency: the offer does not hold the car.', chat(['renter', 'I\'ll think about it.'], ['you', 'Of course. Just so you know, the offer doesn\'t hold the car: if someone pays first, it\'s theirs. Want me to keep it open until tonight?'])),
        S('Discount codes', 'Admins and Sales send discount codes: 10 percent off the rental charge, at most 75 dollars, one per booking, only with marketing consent.', money('A discount code', [['Off the rental charge', '10%'], ['At most', '$75'], ['Codes a booking', 'One']])),
        S('"Can I buy it?"', 'We mostly rent cars. Never say a car is for sale unless an Admin flagged it. We do not lend or lease.', chat(['caller', 'Can I finance this car?'], ['you', 'We don\'t lend or lease, but you can rent it for a week first. If we find one for sale, I\'ll tell you its price.']))
      )
    ],
    quiz: [
      Q('When does a website request open to Sales?', ['At once', '15 minutes after it came in', 'Never', 'The next day'], 1, 'Sales may claim or answer it 15 minutes after it came in.'),
      Q('How long can an offer stay open at most?', ['12 hours', '48 hours', '7 days', 'No limit'], 1, 'An offer stays open at most 48 hours.'),
      Q('An enquiry is about an example car. What do you offer?', ['The example car', 'A real free car of the same kind and price', 'Nothing', 'A discount'], 1, 'Example cars do not exist: offer a real one.'),
      Q('What is the most a percentage discount code takes off?', ['$25', '$75', '$200', 'No cap'], 1, 'A percentage code is capped at $75.'),
      Q('A caller asks to finance a car. What do you say?', ['Yes', 'We do not lend or lease; offer a rental', 'Send them to the owner', 'Quote a loan'], 1, 'We do not lend or lease.')
    ]
  },
  {
    slug: 'sales-in-person', title: 'Sales in person: the desk, cash and the card reader',
    blurb: 'Serving walk-ins, e-signing on the spot, taking payment on the card reader, and handling cash.',
    lessons: [
      L('At the desk',
        S('Walk-ins', 'A walk-in is a renter like any other: one record, the licence checked, the agreement signed and the payment taken before the keys.', steps('Walk-in', ['Find or add the renter', 'Quote and offer', 'Licence and coverage checked', 'Sign on this device', 'Payment and deposit', 'Handover'])),
        S('The card reader', 'From the booking\'s Money tab, Charge on reader takes what is open, and Hold deposit on reader holds the deposit. Cancel stops the reader. A card read on the reader is never saved as the card on file.', list('Card reader', ['Charge on reader', 'Hold deposit on reader', 'Cancel stops it', 'Not saved as the card on file']))
      ),
      L('Cash',
        S('Count it in front of them', 'Count cash in front of the renter and record it at once. Keep it apart from your own money.', steps('Cash', ['Count in front of the renter', 'Record it at once', 'Keep it apart', 'Hand it over as Finance directs'])),
        S('Hand it over', 'Cash goes to CarmaCars within 1 business day, as Finance directs. Finance counts the drawer at the end of the day: balanced, over or short.', rule('Within 1 business day', 'Cash never stays with you.', 'warn')),
        S('"Can I pay all in cash?"', 'Cash is accepted for the rental and the deposit when recorded properly.', chat(['renter', 'Can I pay the deposit in cash?'], ['you', 'Yes. I\'ll count it with you and give you a receipt. It comes back the same way after the return, once the car is checked.']))
      )
    ],
    quiz: [
      Q('Is a card read on the reader saved as the card on file?', ['Yes', 'No, never', 'Only for the deposit', 'Only with consent'], 1, 'A card read on the reader is never saved as the card on file.'),
      Q('When does cash go to CarmaCars?', ['At the end of the month', 'Within 1 business day, as Finance directs', 'When you like', 'Never'], 1, 'Cash is handed over within 1 business day.'),
      Q('Where do you count cash?', ['In the back office', 'In front of the renter', 'At home', 'At the bank'], 1, 'Count it in front of the renter and record it at once.'),
      Q('How is a cash deposit given back?', ['By card', 'The way it came, after the return is checked', 'Never', 'As a credit'], 1, 'A deposit taken in cash is given back the same way.'),
      Q('What comes before the keys for a walk-in?', ['Nothing', 'Licence checked, agreement signed, payment and deposit taken', 'Only payment', 'Only a signature'], 1, 'Every check of a handover applies to a walk-in too.')
    ]
  },
  {
    slug: 'sales-remote', title: 'Sales remote: the extra duties',
    blurb: 'Remote Sales: the activity minimum, peak hours, the reply target, live chat and game leads, and consent rules.',
    lessons: [
      L('Your month',
        S('Touches', 'Remote Sales logs touches: chats, texts, calls and follow-ups. The minimum is 400 a month.', title('400 touches a month', 'The activity minimum')),
        S('Below the minimum', 'Under the minimum, the month\'s commission rate drops one tier. Below the lowest tier the floor is 2.5 percent.', rule('Below 400', 'The rate drops one tier (floor 2.5%).', 'warn')),
        S('Peak hours', 'Cover 20 peak hours a week, Thursday to Sunday afternoons, from noon to 6 pm.', list('Peak hours', ['Thursday to Sunday', 'Noon to 6 pm', '20 hours a week'])),
        S('Reply in 15 minutes', 'On chats, texts and calls assigned on your shift, reply within 15 minutes.', title('15 minutes', 'Reply target on your shift'))
      ),
      L('Live chat and leads',
        S('Live chat', 'Chats waiting for a person show in Live chat. Greet by name when you know it, answer the question asked, then move to a quote.', chat(['visitor', 'Is the RAV4 free next weekend?'], ['you', 'Let me check. Yes, Friday to Sunday it\'s free. Want me to send you an offer now? It takes a minute.'])),
        S('Game leads', 'Discount game leads come with their code. Without marketing consent, talk only about their request and the code they asked for.', rule('Game leads', 'No other offers without consent.', 'warn')),
        S('Owner leads too', 'Remote Sales also works owner leads: Take it, then Update as you go, contacted, qualified, converted or closed with the reason.', steps('A lead', ['Take it', 'Contacted', 'Qualified', 'Converted or closed, with the reason']))
      )
    ],
    quiz: [
      Q('What is the remote Sales activity minimum?', ['100 touches a month', '400 touches a month', '1,000 a week', 'None'], 1, 'The minimum is 400 touches a month.'),
      Q('What happens below the minimum?', ['Nothing', 'The month\'s rate drops one tier (floor 2.5%)', 'No commission at all', 'A warning only'], 1, 'The rate drops one tier, with a 2.5% floor.'),
      Q('Which hours are the peak hours?', ['Monday mornings', 'Thursday to Sunday, noon to 6 pm', 'Nights', 'Any time'], 1, 'Thursday to Sunday afternoons, noon to 6 pm, 20 hours a week.'),
      Q('What is the reply target on your shift?', ['5 minutes', '15 minutes', '1 hour', '24 hours'], 1, 'Remote Sales replies within 15 minutes on their shift.'),
      Q('A game lead has no marketing consent. What may you discuss?', ['Any offer', 'Only their request and the code they asked for', 'Nothing', 'Other cars on sale'], 1, 'Without consent, only their request and their code.')
    ]
  },
  {
    slug: 'owner-recruitment', title: 'Recruiting car owners',
    blurb: 'The pitch to a car owner, what they pay and earn, and the objections: insurance, wear, trust, leaving.',
    lessons: [
      L('The pitch',
        S('What we offer', 'An owner lists their car with us. Managed: we do everything, pricing, renters, handovers and cleaning, and pay them each month less the Revenue Share. Self-Managed: they hand over to their own renters, who book and pay through us.', list('Two ways', ['Managed: we do everything', 'Self-Managed: their renters, our booking and payment'])),
        S('What they pay', 'Each car has a monthly insurance fee and a tracker fee, due every month rented or not. The tracker install has its own invoice. Before going live they pay the first and last month agreed.', money('Owner fees', [['Insurance fee', 'Monthly, as agreed'], ['Tracker fee', 'Monthly, from install'], ['Tracker install', 'One invoice'], ['First and last month', 'Before going live']])),
        S('When they are paid', 'Payouts for the month before arrive on the 10th with a statement. Fees are debited on the 15th after a notice 10 days before.', steps('The owner month', ['10th: payout and statement', '5th: notice of the debit', '15th: fees debited'])),
        S('A flat monthly amount', 'Some owners prefer the same amount every month for a car instead of a revenue share and fees. Only an Admin sets it, car by car.', rule('Flat monthly', 'Admin only, car by car.'))
      ),
      L('Owner objections',
        S('"What about insurance?"', 'Rentals run on our fleet policy once the car is added to it. The owner\'s own policy details are collected.', chat(['owner', 'My insurance won\'t cover rentals.'], ['you', 'Rentals run on our fleet policy once your car is added. That\'s what the monthly insurance fee covers. Your own policy stays in place for your use.'])),
        S('"What about wear and damage?"', 'Every handover has 19 timed photos, a damage diagram and a tracker. Damage is billed to the renter up to the deductible, and claims go through the policy.', chat(['owner', 'Renters will wreck my car.'], ['you', 'Every pickup and return has 19 timed photos and a tracker. Damage is billed to the renter up to the $2,500 deductible, and bigger damage goes through a claim.'])),
        S('"Can I leave?"', 'Yes. 30 days\' notice on a car; the exit date is the end of the notice, or the end of a rental in progress if later.', chat(['owner', 'What if I want out?'], ['you', 'Give 30 days\' notice in your portal. The car leaves at the end of the notice, or after a rental in progress.'])),
        S('"Can you raise my fees?"', 'A higher fee needs 30 days\' written notice; a higher Revenue Share only once the owner signs an updated Vehicle Schedule.', rule('Changes', 'Higher fee: 30 days\' notice. Higher share: the owner signs.'))
      )
    ],
    quiz: [
      Q('What is a Managed owner\'s deal?', ['They do everything', 'We do everything and pay them monthly less the Revenue Share', 'They pay a flat fee only', 'They sell us the car'], 1, 'Managed: we handle everything; they are paid less the Revenue Share.'),
      Q('When are the owner\'s fees due?', ['Only when the car rents', 'Every month, rented or not', 'Once a year', 'Never'], 1, 'The insurance and tracker fees are due every month, rented or not.'),
      Q('When do owners get their payout?', ['The 1st', 'The 10th, with a statement', 'The 15th', 'The 30th'], 1, 'Payouts arrive on the 10th with a statement; fees are debited on the 15th.'),
      Q('An owner wants to leave. What notice applies?', ['None', '30 days on that car', '6 months', '1 year'], 1, '30 days\' notice; the exit is at the end of the notice or of a rental in progress.'),
      Q('Who sets a flat monthly amount for a car?', ['Any staff', 'Only an Admin, car by car', 'The owner alone', 'Finance'], 1, 'Only an Admin, car by car.'),
      Q('Can CarmaCars raise an owner\'s Revenue Share by notice alone?', ['Yes', 'No: the owner signs an updated Vehicle Schedule', 'Yes, with 7 days', 'Only for new cars'], 1, 'A higher share applies only once the owner signs.')
    ]
  },
  {
    slug: 'commission', title: 'Commission',
    blurb: 'How commission is worked out: the Sales tiers in person and remote, the rate of the other functions, and what counts.',
    lessons: [
      L('The tiers',
        S('A share of the rental charge', 'Commission is a share of the rental charge of the rentals you close, never of fees, add-ons or taxes.', title('Commission', 'A share of the rental charge')),
        S('Sales in person', 'In person: 10 percent, 15 percent once the month reaches 50 rental days, and 20 percent from 100 rental days, the month\'s target.', money('Sales in person', [['Under 50 rental days', '10%'], ['From 50', '15%'], ['From 100', '20%']])),
        S('Sales remote', 'Remote: 5, 10 and 15 percent on the same tiers, with the activity minimum.', money('Sales remote', [['Under 50 rental days', '5%'], ['From 50', '10%'], ['From 100', '15%']])),
        S('Other functions', 'Customer service, finance, fleet and field staff earn 10 percent on the rentals they close. Admin can change every rate in Program settings.', rule('Other staff', '10% of the rental charge.'))
      )
    ],
    quiz: [
      Q('Commission is a share of what?', ['The total with tax', 'The rental charge', 'Fees and add-ons', 'The deposit'], 1, 'Commission is a share of the rental charge only.'),
      Q('In person Sales reaches 60 rental days this month. What rate applies?', ['10%', '15%', '20%', '5%'], 1, 'From 50 rental days the rate is 15%; from 100, 20%.'),
      Q('What is the top remote Sales rate?', ['10%', '15%', '20%', '25%'], 1, 'Remote tiers are 5%, 10% and 15%.'),
      Q('What do customer service staff earn on a rental they close?', ['Nothing', '10% of the rental charge', '20%', 'A flat $50'], 1, 'Staff outside Sales earn 10%.'),
      Q('Who can change the commission rates?', ['Anyone', 'An Admin, in Program settings', 'Finance', 'The renter'], 1, 'Admin changes them in Program settings.')
    ]
  },
  // ---------------------------------------------------------------- field work
  {
    slug: 'field-handover', title: 'The handover',
    blurb: 'The ready check, the original licence and card, odometer, fuel, keys, 19 photos, damage, tracker and signatures.',
    lessons: [
      L('The ready check',
        S('Every line green', 'The first step lists what must be done before the car can go: agreement signed, identity verified, coverage confirmed, additional drivers accepted, the calendar held, and the deposit taken.', list('Ready check', ['Agreement signed', 'Identity verified', 'Coverage confirmed', 'Additional drivers accepted', 'Calendar held', 'Deposit taken'])),
        S('Never hand over on a red line', 'Never hand over keys if the ready check fails, the renter does not match the photo, or they do not have the original licence or the card on file. Stop and call us.', rule('Stop', 'A failed check, a face that does not match, no original licence or card: stop and call.', 'warn')),
        S('Fix it on the spot', 'Most red lines are fixed on your phone: sign now on this device, take the licence photos, hand the phone for the card hold, or record an e-Transfer or cash.', steps('Fix on the spot', ['Not signed: sign on this device', 'Not verified: take licence and selfie', 'No deposit: card hold on this phone', 'Or record e-Transfer or cash']))
      ),
      L('The steps, one by one',
        S('The renter and the documents', 'Is this the renter? Compare the person with the photo. Hold the original licence: a photo of a licence is not enough. See the physical card with the same last four digits, in the renter\'s name.', list('Check', ['Person matches the photo', 'Original licence', 'Physical card, same last four'])),
        S('Readings', 'Type the odometer in kilometres. Tap the fuel or charge level, in eighths from empty to full. Count the keys and fobs.', steps('Readings', ['Odometer in km', 'Fuel in eighths', 'Keys and fobs'])),
        S('Photos and damage', 'Take the 19 photos in order. Tap the diagram where damage is, choose where and the type, and add it. Photos wait on the phone without a connection and upload by themselves.', title('19 photos', 'In order, with every damage marked')),
        S('Tracker and signatures', 'The tracker should say in place and reporting. The renter reads the summary, signs, then you sign. Press Hand over the keys.', steps('Finish', ['Tracker reporting', 'Renter reviews the summary', 'Renter signs, then you', 'Hand over the keys']))
      )
    ],
    quiz: [
      Q('The renter shows a photo of their licence on their phone. Can you proceed?', ['Yes', 'No: you need the original licence', 'Yes, if the face matches', 'Ask the renter to email it'], 1, 'A photo of a licence is not enough.'),
      Q('How many photos does a handover take?', ['5', '10', '19', '50'], 2, 'The photo set has 19 photos in order.'),
      Q('How is fuel recorded?', ['In litres', 'In eighths from empty to full', 'As a percentage typed', 'Not recorded'], 1, 'Tap the level on the gauge, in eighths.'),
      Q('The ready check shows the deposit is not taken. What can you do?', ['Hand over anyway', 'Card hold on this phone, or record e-Transfer or cash', 'Cancel the booking', 'Skip it'], 1, 'Fix it on the spot: card hold on your phone, or e-Transfer or cash.'),
      Q('The renter\'s face does not match the photo on file. What do you do?', ['Proceed', 'Stop: do not release the car, and call us', 'Take a new selfie', 'Ask for a second ID'], 1, 'Stop and call us.')
    ]
  },
  {
    slug: 'field-return-and-cash', title: 'Returns, cash and signing in the field',
    blurb: 'The return check, late and fuel readings, damage at the return, cash and e-Transfer deposits, and signing on your phone.',
    lessons: [
      L('The return',
        S('Check with the renter', 'At the return check the odometer, fuel or charge, keys and cleanliness, take the photos and compare with the pickup. The renter signs on your screen.', steps('The return', ['Odometer and fuel', 'Keys and cleanliness', 'Photos compared with pickup', 'The renter signs'])),
        S('The readings make the charges', 'A late return, kilometres over the allowance and less fuel than at pickup are charged from your readings, so record them exactly.', rule('Exact readings', 'Your readings decide the charges.', 'warn')),
        S('New damage', 'Mark new damage on the diagram with close-ups. Do not promise the renter a charge or no charge: an Admin decides, with the photos.', chat(['renter', 'Will I be charged for that?'], ['you', 'I\'ve recorded it with photos. An Admin reviews it against the pickup photos and contacts you before anything is charged.']))
      ),
      L('Cash and signing on your phone',
        S('Cash deposits', 'Paid in cash: count the amount in front of the renter and press I received. Keep it apart from your own money and hand it to CarmaCars within 1 business day, as Finance directs.', steps('Cash', ['Count in front of them', 'I received', 'Keep it apart', 'Hand over within 1 business day'])),
        S('e-Transfer', 'Paid by e-Transfer: type the reference number from their confirmation and record it.', title('Record the e-Transfer', 'With the reference number')),
        S('Sign now on this device', 'Not signed yet? Sign now on this device: check the name matches the licence and you saw the original, hand the phone over, and take it back when they finish.', list('Sign on your phone', ['Name matches the licence', 'You saw the original', 'Hand the device over', 'Back to the staff view']))
      )
    ],
    quiz: [
      Q('What decides the late, kilometre and fuel charges?', ['The renter\'s word', 'Your readings at the return', 'The office\'s guess', 'Nothing'], 1, 'The readings you record decide the charges.'),
      Q('A renter asks if they will be charged for new damage. What do you say?', ['Yes', 'No', 'An Admin reviews it with the photos and contacts them first', 'Pay me now'], 2, 'Never promise; an Admin decides with the photos.'),
      Q('You received a cash deposit. When does it go to CarmaCars?', ['At month end', 'Within 1 business day', 'Never', 'When the renter returns'], 1, 'Within 1 business day, as Finance directs.'),
      Q('What do you record for an e-Transfer?', ['Nothing', 'The reference number from their confirmation', 'Their bank password', 'A photo of the car'], 1, 'Type the reference number and record it.'),
      Q('Before handing your phone to sign, what do you check?', ['Their email', 'The name matches the licence and you saw the original', 'Their address', 'Nothing'], 1, 'Check the name and the original licence.')
    ]
  },
  // ---------------------------------------------------------------- finance
  {
    slug: 'finance-deposits-refunds', title: 'Finance: deposits, refunds and payments',
    blurb: 'Settling deposits, the toll window, refunds by the policy, payments received another way, and the day\'s cash count.',
    lessons: [
      L('Settling a deposit',
        S('The settlement', 'Settle the deposit applies what is owed, holds back what an open item needs, and releases the rest. What the deposit does not cover is charged to the card on file.', steps('Settle', ['Charges owed', 'Hold back for open items', 'Release the rest'])),
        S('The toll window', 'Tolls and tickets can take up to 7 days to come in. Inside that window the rest of the deposit is held back until the window ends, unless you release it sooner.', rule('Toll window', '7 days; the hold-back can be released early.')),
        S('Something still open', 'An incident, a claim, unpriced damage or an unmatched toll keeps the whole deposit. Damage: only an Admin keeps the deposit or bills up to the 2,500 dollar deductible.', rule('Open items', 'Keep the deposit; damage goes to an Admin.', 'warn')),
        S('Card holds lapse', 'A card hold lapses after about 7 days. While the car is out or not settled, the hold is collected in full a day and a half before it lapses, and the settlement refunds the rest.', title('Holds', 'Collected before they lapse; refunded at settlement'))
      ),
      L('Refunds and payments',
        S('Refunds by the policy', 'Refunds waiting shows the policy maths: what was paid, the tier, the percentage back and what is kept. Approve or decline with the reason. Above your limit, an Admin approves.', list('A refund', ['Paid', 'The tier', 'Percentage back', 'What is kept'])),
        S('Paid another way', 'A renter paid by e-Transfer, cheque or cash? Record the payment with the date, the reference and the proof. A partial payment leaves the rest open.', steps('Record a payment', ['Paid by', 'Date received', 'Reference', 'Proof', 'Record payment'])),
        S('The drawer', 'At the end of the day count the drawer and record the count. The difference shows balanced, over or short.', title('Record the count', 'Balanced, over or short'))
      )
    ],
    quiz: [
      Q('How long is the toll window?', ['1 day', '7 days', '30 days', '90 days'], 1, 'Tolls and tickets can take up to 7 days to come in.'),
      Q('An incident is open on a returned car. What happens to the deposit?', ['Release it', 'The whole deposit is kept until it is resolved', 'Half is released', 'It is charged at once'], 1, 'Something still open keeps the whole deposit.'),
      Q('Who may keep a deposit for damage?', ['Finance', 'An Admin', 'Field staff', 'The renter'], 1, 'Only an Admin keeps a deposit or bills damage.'),
      Q('A refund is above your limit. What happens?', ['It is refused', 'It waits for an Admin', 'It goes through anyway', 'It is split'], 1, 'Above your limit, an Admin approves.'),
      Q('What do you record at the end of the day?', ['Nothing', 'The drawer count', 'The weather', 'The fleet mileage'], 1, 'Count the drawer and record it: balanced, over or short.')
    ]
  },
  {
    slug: 'finance-tolls-owners', title: 'Finance: tolls, owners and insurers',
    blurb: 'Reading toll notices, who pays, owner invoices and debits, payouts and statements, and insurer invoices.',
    lessons: [
      L('Tolls and tickets',
        S('Read a notice', 'Read a notice: upload the PDF, photo or CSV, check each line against the notice, then confirm and import. Renters matched with high confidence are charged at import, with the notice and our fee.', steps('A notice', ['Read it', 'Check each line', 'Save as checked', 'Confirm and import'])),
        S('Who pays', 'Decide who pays a toll: charge the renter, bill it to the owner, or CarmaCars pays. A renter pays the amount plus 15 dollars a toll or 40 dollars a ticket.', list('Who pays', ['Charge the renter', 'Bill to the owner', 'CarmaCars pays']))
      ),
      L('Owners and insurers',
        S('The owner month', 'Owner fees are debited on the 15th after a notice 10 days before. Payouts and statements go out on the 10th.', steps('The owner month', ['10th: payouts and statements', '5th: debit notice', '15th: debits'])),
        S('A returned debit', 'Returned for insufficient funds: a 50 dollar late fee once, and the same amount tried again within 30 days. Returned for another reason: no retry, the debit pauses and the owner is emailed.', money('Returned debit', [['Insufficient funds', '$50 late fee, retry within 30 days'], ['Other reason', 'No retry, debit paused']])),
        S('Insurer invoices', 'Insurer-billed rentals are invoiced to the insurer: each charge a line of its own, like the VLF at a rate a day, with the claim number.', title('Insurer invoice', 'Each charge its own line, with the claim number'))
      )
    ],
    quiz: [
      Q('A renter is matched to a toll with high confidence. When are they charged?', ['Never', 'At import, with the notice and our fee', 'At the next booking', 'After 90 days'], 1, 'High-confidence matches are charged at import.'),
      Q('When are owner fees debited?', ['The 1st', 'The 10th', 'The 15th, after a 10-day notice', 'The 30th'], 2, 'Debits are on the 15th after a notice 10 days before.'),
      Q('An owner\'s debit returns for insufficient funds. What happens?', ['Nothing', 'A $50 late fee once, and a retry within 30 days', 'The car is removed', 'A retry the same day'], 1, 'A $50 late fee once; the same amount is tried again within 30 days.'),
      Q('A debit returns because the account is closed. What happens?', ['Retry tomorrow', 'No retry; the debit pauses and the owner is emailed', 'Late fee and retry', 'Charge the card'], 1, 'Another reason: no retry and no late fee; the debit pauses.'),
      Q('What goes on every insurer invoice line?', ['Nothing special', 'The claim number, with each charge on its own line', 'The renter\'s card', 'The owner\'s bank'], 1, 'Each charge is its own line, with the claim number.')
    ]
  },
  // ---------------------------------------------------------------- fleet
  {
    slug: 'fleet-cars', title: 'Fleet: cars, checks and listings',
    blurb: 'Daily checks, maintenance, photo reviews after a return, listings and plates, and the turnaround between trips.',
    lessons: [
      L('Keeping cars ready',
        S('Daily checks', 'Open the daily checks morning and evening. Tick OK or Problem with a note, and save.', steps('Daily check', ['Opening or closing check', 'OK or Problem with a note', 'Save'])),
        S('The turnaround', 'Between trips the car needs a turnaround of 2 hours for cleaning and checks. Do not squeeze a booking into it.', rule('Turnaround', '2 hours between trips.')),
        S('Car ready means', 'A car is ready when the fuel is full or the charge at 80 percent, it is clean, and the extras are in.', list('Ready', ['Fuel full or charge 80%', 'Clean', 'Extras in']))
      ),
      L('After a return',
        S('Photo reviews', 'After a return, compare the return photos with the pickup photos. New damage goes to an Admin with the photos.', title('Photo review', 'Pickup against return')),
        S('Waiving a charge', 'Fleet can waive a return charge, like fuel or cleaning, with a reason. Damage is an Admin\'s decision.', rule('Waive', 'With a reason; never damage.', 'warn')),
        S('Listings and plates', 'Listing photos stay private until the plate is covered or marked not visible. Check each photo before it goes public.', title('Plates', 'Covered before a photo is public'))
      )
    ],
    quiz: [
      Q('How long is the turnaround between trips?', ['30 minutes', '2 hours', '1 day', 'None'], 1, 'The turnaround is 2 hours.'),
      Q('What does "car ready" mean?', ['Parked', 'Fuel full or charge 80%, clean, extras in', 'Keys found', 'Just washed'], 1, 'Full fuel or 80% charge, clean, extras in.'),
      Q('Can fleet waive a damage charge?', ['Yes', 'No: damage is an Admin\'s decision', 'Only small damage', 'With the owner\'s OK'], 1, 'Fleet waives return charges with a reason, never damage.'),
      Q('When does a listing photo go public?', ['At once', 'Once the plate is covered or marked not visible', 'After a week', 'Never'], 1, 'Photos stay private until the plate is covered.'),
      Q('What do you compare in a photo review?', ['Prices', 'Return photos against pickup photos', 'Owner documents', 'Insurance slips'], 1, 'Compare the return photos with the pickup photos.')
    ]
  },
  {
    slug: 'fleet-field-jobs', title: 'Fleet: field jobs, hours and trackers',
    blurb: 'Scheduling handovers and returns, field hours and corrections, trackers that stop reporting.',
    lessons: [
      L('Field jobs',
        S('Jobs from bookings', 'Each confirmed booking makes its handover and return jobs. When the booking moves, its jobs move too, unless you changed them.', title('Jobs follow the booking', 'Unless you changed them')),
        S('Assign and move', 'Change a job with Assign, Reassign, Move or Cancel. Handovers without a job are listed first: press Schedule.', list('A job', ['Assign or Reassign', 'Move: time and place', 'Cancel', 'Schedule a missing one'])),
        S('Trackers', 'A car whose tracker is not reporting may go only with a reason, and an Admin gets an urgent task at once.', rule('No tracker signal', 'A reason, and an Admin is told at once.', 'warn'))
      ),
      L('Field hours',
        S('Corrections', 'Someone forgot to clock out? Clock out for them with the time and the reason. Add, change or remove a shift, each with a reason; the change is kept in a log.', steps('Fix hours', ['Clock out for them', 'Add hours', 'Change or Remove', 'Always a reason'])),
        S('Locked periods', 'Once an Admin approves the pay run of a period, its shifts are locked. You see hours only, not rates or pay.', title('Approved periods are locked', 'Ask an Admin'))
      )
    ],
    quiz: [
      Q('A booking moves to a new date. What happens to its jobs?', ['Nothing', 'They move too, unless you changed them', 'They are cancelled', 'They are duplicated'], 1, 'Jobs made from a booking follow it unless changed by hand.'),
      Q('A car must go but its tracker is not reporting. What then?', ['Never release', 'Release with a reason; an Admin is told at once', 'Release silently', 'Remove the tracker'], 1, 'With a reason, and an Admin gets an urgent task.'),
      Q('Can you change shifts in an approved pay period?', ['Yes', 'No: they are locked; ask an Admin', 'Only add', 'Only remove'], 1, 'Approved periods are locked.'),
      Q('What does every hours correction need?', ['Nothing', 'A reason', 'The owner\'s OK', 'A photo'], 1, 'Each change needs a reason and is logged.'),
      Q('Do fleet staff see field pay rates?', ['Yes', 'No: hours only', 'Only totals', 'Only overtime'], 1, 'Fleet sees hours, not rates or pay.')
    ]
  },
  // ---------------------------------------------------------------- Admin
  {
    slug: 'admin-team', title: 'Admin: the team, limits and the academy',
    blurb: 'Staff functions and work modes, limits, commission settings, the academy: unlocking early, the gate and editing lessons.',
    lessons: [
      L('People and functions',
        S('Functions', 'A staff member holds any set of functions: customer service, fleet, finance, sales and field work. Each adds its menu group and its academy path.', list('Functions', ['Customer service', 'Fleet', 'Finance', 'Sales: in person or remote', 'Field work'])),
        S('Limits', 'Each person has a single limit: the largest refund or charge they make alone. Above it, you approve.', rule('Limits', 'Above a person\'s limit, an Admin approves.')),
        S('Commission settings', 'Program settings hold the Sales tiers in person and remote, the activity minimum, peak hours and the rate of the other functions.', title('Program settings', 'Every rate in one place'))
      ),
      L('The academy',
        S('Progress', 'Admin > Academy shows each staff member\'s progress: sections passed of their paths, attempts and scores.', title('Progress per person', 'Sections passed, attempts, scores')),
        S('Open a section early', 'You can open a section early for one person, with a reason, for example someone experienced moving to a new function.', steps('Open early', ['Open the person', 'Choose the section', 'Give the reason'])),
        S('The gate', 'The academy gate is off by default: the academy records progress only. On, a staff member opens only the academy, the guide and their profile until they pass their paths.', rule('Academy gate', 'Off by default. On: the portal waits for the paths.', 'warn')),
        S('Editing', 'You edit sections, lessons, scenes and questions in the editor. Each scene has a caption, the words the voice says, and its picture. Keep it short and true to the policy.', list('A scene', ['Caption', 'Narration', 'Picture: title, chat, list, steps, money or rule']))
      )
    ],
    quiz: [
      Q('Is the academy gate on by default?', ['Yes', 'No: off, progress only', 'Only for Sales', 'Only for field'], 1, 'Off by default: the academy records progress only.'),
      Q('A person\'s refund is above their single limit. What happens?', ['Refused', 'An Admin approves', 'Finance approves', 'It goes through'], 1, 'Above their limit, an Admin approves.'),
      Q('What does opening a section early need?', ['Nothing', 'A reason', 'The person\'s signature', 'A quiz pass'], 1, 'Every early opening is recorded with a reason.'),
      Q('What does each scene of a lesson have?', ['A video file', 'A caption, the narration and a picture', 'Only text', 'A PDF'], 1, 'Scenes are made in the browser: caption, narration and a picture.'),
      Q('Where are commission rates changed?', ['In code', 'Program settings', 'The owner portal', 'Nowhere'], 1, 'Program settings hold every rate.')
    ]
  },
  {
    slug: 'admin-decisions', title: 'Admin: money decisions and owners',
    blurb: 'Damage and deposits, waivers, prices far under the rate sheet, owner terms and notices, flat monthly payments.',
    lessons: [
      L('Damage and deposits',
        S('Keep or bill', 'Keep the whole deposit for damage, or bill a damage charge up to the 2,500 dollar deductible: the deposit pays first, then the card on file. More goes through a claim.', steps('Damage', ['Compare the photos', 'Keep the deposit or bill up to $2,500', 'Over that: a claim'])),
        S('Waivers', 'Deposit waivers and prices far under the rate sheet come to you, each with the staff member\'s reason. Approve or correct.', title('Flags for an Admin', 'Waivers and low prices, with reasons'))
      ),
      L('Owner terms',
        S('Lower and higher', 'A lower fee or share applies from the notice date. A higher fee needs 30 days\' written notice; a higher Revenue Share applies only once the owner signs an updated Vehicle Schedule.', money('Changing terms', [['Lower', 'From the notice date'], ['Higher fee', '30 days\' notice'], ['Higher share', 'Owner signs']])),
        S('Above the signed terms', 'Setting a booking\'s Revenue Share above the car\'s signed terms is Admin only, with the reason. The owner sees it.', rule('Above terms', 'Admin only, with a reason the owner sees.', 'warn')),
        S('Flat monthly', 'A flat monthly payment is set car by car. An owner with every car on it signs the Flat-Rate Enrollment Agreement.', title('Flat monthly', 'The Flat-Rate Enrollment Agreement'))
      )
    ],
    quiz: [
      Q('Damage is estimated at $4,000. What can be billed to the renter directly?', ['$4,000', 'Up to the $2,500 deductible; the rest through a claim', 'Nothing', '$500'], 1, 'Bill up to the deductible; more goes through a claim.'),
      Q('What pays a damage charge first?', ['The card on file', 'The deposit', 'The owner', 'CarmaCars'], 1, 'The deposit pays first, then the card on file.'),
      Q('You raise an owner\'s fee. What is needed?', ['Nothing', '30 days\' written notice', 'A phone call', 'A new car'], 1, 'A higher fee comes with 30 days\' written notice.'),
      Q('You set a booking\'s Revenue Share above the signed terms. What is required?', ['Nothing', 'Admin only, with the reason', 'The renter\'s OK', 'Finance\'s OK'], 1, 'Only an Admin, with the reason the owner sees.'),
      Q('Which agreement does an owner with every car on a flat monthly payment sign?', ['None', 'The Flat-Rate Enrollment Agreement', 'A lease', 'The standard one'], 1, 'They sign the Flat-Rate Vehicle Enrollment Agreement.')
    ]
  }
];

// the paths: their sections in order (a section on several paths is passed once)
export const PATHS = [
  { code: 'cs', title: 'Customer service', blurb: 'Requests, offers, renters\' questions, documents and signing, insurer-billed rentals.', sections: ['prices-and-deposits', 'coverage-and-drivers', 'trip-rules', 'cs-requests', 'documents-and-signing', 'insurer-billed-rentals'] },
  { code: 'sales_in_person', title: 'Sales in person', blurb: 'Selling at the desk: the policies, quotes and offers, cash and the card reader, owner recruitment, commission.', sections: ['prices-and-deposits', 'coverage-and-drivers', 'trip-rules', 'sales-requests-and-quotes', 'documents-and-signing', 'sales-in-person', 'owner-recruitment', 'commission'] },
  { code: 'sales_remote', title: 'Sales remote', blurb: 'Selling by chat, text and phone: the policies, quotes and offers, the remote duties, owner recruitment, commission.', sections: ['prices-and-deposits', 'coverage-and-drivers', 'trip-rules', 'sales-requests-and-quotes', 'sales-remote', 'owner-recruitment', 'commission'] },
  { code: 'field', title: 'Field work', blurb: 'Handovers and returns done right: the checks, photos, readings, cash and signing in the field.', sections: ['trip-rules', 'field-handover', 'field-return-and-cash', 'coverage-and-drivers'] },
  { code: 'finance', title: 'Finance', blurb: 'Deposits, refunds, payments, tolls, owner debits and payouts, insurer invoices.', sections: ['prices-and-deposits', 'trip-rules', 'finance-deposits-refunds', 'finance-tolls-owners', 'insurer-billed-rentals'] },
  { code: 'fleet', title: 'Fleet', blurb: 'Cars ready, checks, photo reviews, listings, field jobs, hours and trackers.', sections: ['trip-rules', 'fleet-cars', 'fleet-field-jobs', 'field-handover'] },
  { code: 'admin', title: 'Admin', blurb: 'Every policy, the team and the academy, and the money decisions only an Admin makes.', sections: ['prices-and-deposits', 'coverage-and-drivers', 'trip-rules', 'insurer-billed-rentals', 'owner-recruitment', 'admin-team', 'admin-decisions'] }
];
