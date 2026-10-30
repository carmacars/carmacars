// The policies every renter-facing role needs (customer service, Sales, field work, Finance, Fleet, Admin), from the guides
// (docs/guides/content) and the policy in the database (site_facts, program_settings) as of Release 21b.
import { S, title, chat, list, steps, money, rule, Q, L } from './helpers.mjs';

export const POLICY_SECTIONS = [
  {
    slug: 'prices-and-deposits', title: 'Prices, offers and deposits',
    blurb: 'How a price is built, what an offer does, and the deposit from the hold to the release. With the renter\'s questions about price and deposit.',
    lessons: [
      L('How a price is built',
        S('Every booking starts as a request', 'A renter never books instantly. They send a request, we check the car and the renter, and we answer with an offer.', title('Request, offer, pay', 'Never instant: we always check first')),
        S('The rental charge', 'The rental charge comes from the car\'s rate sheet: a daily rate, a weekend rate, and weekly and monthly rates for longer rentals. The site picks the rate that applies to the days booked.', list('The rate sheet', ['Daily rate', 'Weekend rate', 'Weekly rate from 7 days', 'Monthly rate for long rentals'])),
        S('Then the fees and the tax', 'On top of the rental charge come the fees the booking needs, such as a young driver fee, an additional driver, delivery or add-ons. HST is 13 percent on the lines that carry it.', money('An example', [['Rental charge, 3 days', '$297.00'], ['Young driver fee, 3 days at $20', '$60.00'], ['Delivery', '$50.00'], ['HST 13%', '$52.91']], ['Total', '$459.91'])),
        S('Kilometres', 'Each booking has a kilometre allowance a day. Kilometres over the allowance cost the car\'s overage rate, 35 cents a kilometre on most cars, read from the odometer at pickup and return.', rule('Kilometres', 'An allowance a day; over it, the car\'s rate a km (usually $0.35).')),
        S('Non-refundable bookings', 'A renter can choose a non-refundable booking: 10 percent off the rental charge, but no refund if they cancel. Say both halves every time.', rule('Non-refundable', '10% off the rental charge, and no refund on a cancellation.', 'warn'))
      ),
      L('What an offer does',
        S('An offer is our answer', 'The offer shows the car, the dates, the places and the price. The renter approves it, signs the agreement and pays.', steps('From offer to booking', ['Review the offer', 'Sign the agreement', 'Pay: the card is authorized', 'Confirmed: the card is charged'])),
        S('An offer does not hold the car', 'An offer stays open for 24 hours unless we set another time, at most 48. It does not hold the car: the first renter to pay gets it. If someone else pays first, the renter sees "This car was just taken" and their authorization is released.', rule('First to pay gets the car', 'Tell a renter who hesitates: the offer does not hold the car.', 'warn')),
        S('Changing an offer', 'An offer that is out is changed in place: Edit the offer, then save and send the update. There is no need to withdraw it first.', title('Edit the offer', 'Save and send the update')),
        S('Discount codes', 'A discount code comes off the rental charge only, never add-ons, fees, the deposit or taxes. A percentage code is capped at 75 dollars, one code per booking, never two codes together.', list('Discount codes', ['Rental charge only', 'Percentage codes capped at $75', 'One code a booking', 'Offers only with marketing consent']))
      ),
      L('The deposit, start to finish',
        S('A refundable hold', 'The deposit is refundable. It is a hold on the renter\'s card on file, taken about an hour before pickup, not when they pay for the booking.', title('The deposit', 'Held about an hour before pickup')),
        S('How much', 'Each car has a deposit tier: 500, 1,000, 2,500 or 5,000 dollars. Higher-value cars use a higher tier. The offer and the booking always show the amount.', money('Deposit tiers', [['Tier 1', '$500'], ['Tier 2', '$1,000'], ['Tier 3', '$2,500'], ['Tier 4', '$5,000']])),
        S('Other ways to pay it', 'Field staff can also take the deposit in cash or by e-Transfer at the handover. Cash is counted in front of the renter and recorded at once.', list('Deposit methods', ['Card hold (the usual way)', 'e-Transfer', 'Cash, counted and recorded'])),
        S('After the return', 'After the return we check the car. Tolls, fuel, kilometres over and damage up to the deductible come off the deposit first. The balance comes back within 7 business days.', steps('Settling the deposit', ['Return checked', 'Charges taken off', 'Balance released within 7 business days'])),
        S('Holding some back', 'If a toll, a ticket or a claim is still open, we may hold back what we expect it to cost, for up to 30 days. Tell the renter why, and when they can expect the rest.', rule('Holdback', 'Up to 30 days for an open toll, ticket or claim.', 'warn'))
      ),
      L('Questions about price and deposit',
        S('"Why is it so expensive?"', 'Do not argue. Explain what the price includes, then offer a real choice.', chat(['renter', 'That is a lot for three days.'], ['you', 'It includes liability coverage and a daily kilometre allowance. A weekly rental brings the daily price down, and a non-refundable booking takes 10% off. Want me to price either?'])),
        S('"Why do you need a deposit?"', 'The deposit protects the car and the next renter. It is a hold, not a charge, and it comes back.', chat(['renter', 'Why do you hold my money?'], ['you', 'It is a hold on your card, not a charge. It covers things like tolls or fuel after the trip. The balance is released within 7 business days of the return.'])),
        S('"Can I skip the deposit?"', 'Never promise a waiver. Only an Admin waives a deposit, with a reason that is logged.', chat(['renter', 'Can you skip the deposit for me?'], ['you', 'I can\'t waive it myself. I can ask an Admin, but please plan on the hold. If a card is the problem, field staff can take it in cash or by e-Transfer at pickup.'])),
        S('"Can I pay with debit?"', 'The booking is paid by card. Card coverage needs a credit card in the renter\'s name; debit and prepaid cards are refused for that.', chat(['renter', 'Can I use my debit card?'], ['you', 'To pay, a card in your name works. If you want your card\'s rental coverage, it has to be a credit card: debit and prepaid cards do not include it.']))
      )
    ],
    quiz: [
      Q('When is the deposit taken?', ['When the renter pays for the booking', 'About an hour before pickup', 'At the return', 'Only if there is damage'], 1, 'The deposit is a hold on the card on file, taken about an hour before pickup.'),
      Q('A renter has an open offer but has not paid. Another renter pays first for the same car. What happens?', ['The first renter keeps the car for 24 hours', 'The car goes to the renter who paid', 'Both bookings are confirmed', 'Staff must choose'], 1, 'An offer does not hold the car: the first renter to pay gets it.'),
      Q('What does a non-refundable booking give and take?', ['5% off, half refunded', '10% off the rental charge, no refund on a cancellation', 'Free delivery, no refund', 'No deposit, no refund'], 1, 'Non-refundable is 10% off the rental charge, and no refund if the renter cancels.'),
      Q('What can a discount code come off?', ['The whole total', 'The deposit', 'The rental charge only', 'Fees and add-ons only'], 2, 'Codes come off the rental charge only, never add-ons, fees, the deposit or taxes.'),
      Q('How soon is a deposit balance released after the return?', ['Same day', 'Within 7 business days', 'After 30 days', 'After the next rental'], 1, 'The balance comes back within 7 business days. An open toll, ticket or claim can hold some back up to 30 days.'),
      Q('A renter asks you to skip the deposit. What do you say?', ['Yes, for a good customer', 'Only an Admin can waive it, with a reason; plan on the hold', 'Deposits are optional', 'Pay double rent instead'], 1, 'Only an Admin waives a deposit, with a logged reason. Field staff can take cash or e-Transfer if a card is the problem.')
    ]
  },
  {
    slug: 'coverage-and-drivers', title: 'Coverage, ages and licences',
    blurb: 'The three ways a car is covered (OPCF 27, a credit card\'s rental coverage, the CarmaCars Protection Plan), young drivers and licences.',
    lessons: [
      L('Three ways to cover the car',
        S('Liability is included', 'Every rental includes liability coverage. The renter\'s choice is about damage to the car itself.', title('Damage to the car', 'Liability is included; the renter chooses how damage is covered')),
        S('Option 1: OPCF 27', 'OPCF 27 is an endorsement on the renter\'s own Ontario auto policy that covers a car they rent. The proof: the insurer, the policy number, an expiry after the return date, and the page that shows OPCF 27.', list('OPCF 27 proof', ['The insurer', 'The policy number', 'Expiry after the return date', 'The page showing OPCF 27'])),
        S('Option 2: the credit card', 'The renter pays with a credit card in their own name that includes rental car coverage. Debit and prepaid cards are refused. Most cards stop at a car priced 65,000 or 85,000 dollars, and some of our cars cost more.', rule('Card coverage', 'A credit card in the renter\'s name; the issuer decides a claim, never us.', 'warn')),
        S('Option 3: the Protection Plan', 'The CarmaCars Protection Plan is priced in the offer, for the car and the driver\'s age. Customer service sets its price. A claim still costs the renter the deductible.', title('The Protection Plan', 'Priced in the offer')),
        S('Changing the choice', 'The renter can change their coverage any time before pickup. The agreement changes with it, and they sign the new version.', steps('Change of coverage', ['The renter asks', 'We update the booking', 'They sign the new version']))
      ),
      L('Young drivers, licences and extra drivers',
        S('Ages', 'Renters can be 18 or older on some cars. Drivers aged 18 to 20 pay 35 dollars a day; 21 to 25 pay 20 dollars a day. From 26 there is no young driver fee. Some cars set their own fee.', money('Young driver fees', [['18 to 20', '$35 a day'], ['21 to 25', '$20 a day'], ['26 and over', 'None']])),
        S('Which cars', 'Drivers aged 18 to 20 are allowed only on the cars that allow them. If the car asked for does not, offer one that does.', rule('18 to 20', 'Only on cars that allow it. Offer a car that does.')),
        S('Licences', 'We accept an Ontario G2 or G. A licence from elsewhere is reviewed by a person before we confirm. It must be valid past the return date.', list('Licence', ['Class G2 or G', 'Others: reviewed by a person', 'Valid past the return'])),
        S('Additional drivers', 'Each additional driver adds 25 percent of the daily rate, up to 4 drivers. Each one signs the agreement with their own link, or on our device.', rule('Additional drivers', '25% of the daily rate each, up to 4; each signs.'))
      ),
      L('Questions about coverage',
        S('"My card covers it, right?"', 'Never tell a renter they are covered. The card\'s issuer decides. Send the card list and ask them to call the number on the back of their card.', chat(['renter', 'My Visa covers rentals, so I\'m fine?'], ['you', 'Many cards do, but only your bank can confirm it for this car and these dates. Here is our list of cards with their limits. Please call the number on the back of your card before pickup.'])),
        S('The car is over the card\'s limit', 'If the car costs more than the card covers, or the card excludes the make, offer OPCF 27 or the Protection Plan instead.', chat(['renter', 'My card stops at $65,000.'], ['you', 'This car is above that, so your card would not cover it. You can add OPCF 27 to your own policy, or take our Protection Plan. Want the Plan\'s price?'])),
        S('"I don\'t have OPCF 27"', 'Many renters have never heard of it. It is quick to add with most insurers.', chat(['renter', 'What is OPCF 27? I don\'t have it.'], ['you', 'It is an endorsement your insurer adds to your policy to cover a rental car. Many add it in one call. If not, our Protection Plan covers it instead.'])),
        S('"I\'m 19"', 'Answer with the fee and the cars that allow it.', chat(['renter', 'I\'m 19, can I rent?'], ['you', 'Yes, on the cars that allow drivers aged 18 to 20, with a $35 a day young driver fee. Let me show you which ones are free for your dates.']))
      )
    ],
    quiz: [
      Q('What proves OPCF 27?', ['A photo of the licence', 'The insurer, policy number, an expiry after the return and the page showing OPCF 27', 'A bank statement', 'A verbal promise'], 1, 'The proof is the insurer, the policy number, an expiry after the return date and the page that shows OPCF 27.'),
      Q('A renter wants to use card coverage with a debit card. What do you say?', ['That works', 'Only a credit card in their name includes it; debit and prepaid are refused', 'Debit works for cars under $65,000', 'Ask Finance'], 1, 'Card coverage needs a credit card in the renter\'s own name.'),
      Q('A renter asks: "Am I covered by my card?"', ['Yes', 'No', 'Only the card\'s issuer can say: send the card list and ask them to call their bank', 'Only if it is Visa'], 2, 'Never tell a renter they are covered. The issuer decides a claim.'),
      Q('What is the young driver fee for a 22-year-old?', ['None', '$20 a day', '$35 a day', '$50 a day'], 1, 'Drivers aged 21 to 25 pay $20 a day; 18 to 20 pay $35 a day.'),
      Q('What does each additional driver cost?', ['Nothing', '25% of the daily rate', '$10 a booking', 'The same as the renter'], 1, 'Each additional driver adds 25% of the daily rate, up to 4 drivers.'),
      Q('When can a renter change their coverage choice?', ['Never', 'Any time before pickup, signing the new version', 'Only at pickup', 'Only with an Admin'], 1, 'They can change it any time before pickup; the agreement changes and they sign it.')
    ]
  },
  {
    slug: 'trip-rules', title: 'Cancellations, late returns, damage, tolls',
    blurb: 'The rules of the trip: cancelling and changing, late returns, kilometres, fuel, cleaning, tolls and tickets, damage and the $2,500 deductible.',
    lessons: [
      L('Cancelling and changing',
        S('The cancellation table', 'For a standard booking the refund depends on when the renter cancels. Within 24 hours of booking and 48 hours or more before pickup: 95 percent back. 48 hours or more before pickup: 75 percent. 24 to 48 hours: 50 percent. Under 24 hours: nothing.', money('Standard booking: cancelled', [['Within 24 h of booking, 48 h+ before pickup', '95% back'], ['48 h or more before pickup', '75% back'], ['24 to 48 h before pickup', '50% back'], ['Under 24 h before pickup', 'No refund']])),
        S('Non-refundable means none', 'A non-refundable booking gets no refund. The deposit is taken at pickup, so none is held when someone cancels before it.', rule('Non-refundable', 'No refund. No deposit is held before pickup.', 'warn')),
        S('Extend instead of cancel', 'A renter who wants more time asks to extend before the return time, and pays for the extension before the current return. A date change shows the difference and is signed.', steps('Extending', ['Ask before the return time', 'We approve', 'Pay before the current return']))
      ),
      L('On the trip: late, kilometres, fuel, tolls',
        S('Late returns', 'There is a 30 minute grace period. After it, a late return costs 25 dollars an hour. A renter running late should ask to extend before their return time.', money('Late return', [['Grace', '30 minutes'], ['After that', '$25 an hour']])),
        S('Fuel', 'Return the car with the fuel it had at pickup. Less is charged at the pump price plus 25 percent, and a 25 dollar service fee. A prepaid full tank means no fuel charge. Electric cars: 10 dollars for each 10 percent of battery.', list('Fuel', ['Same level as pickup', 'Less: pump price + 25%, + $25 service fee', 'Prepaid full tank: no charge', 'EV: $10 per 10% of battery'])),
        S('Cleaning and smoking', 'Normal use is fine. Extra cleaning costs 75 dollars, heavy soiling or odour 250, pet hair 150, and smoking 300.', money('Cleaning', [['Cleaning', '$75'], ['Heavy soiling or odour', '$250'], ['Pet cleaning', '$150'], ['Smoking', '$300']])),
        S('Tolls and tickets', 'Tolls and tickets are the renter\'s, including the 407 ETR. When one reaches us we pay it and charge the amount plus our fee, 15 dollars a toll and 40 dollars a ticket, to the card on file, with a copy of the notice.', money('Tolls and tickets', [['Toll', 'Amount + $15'], ['Ticket, fine or towing', 'Amount + $40']]))
      ),
      L('Damage and the deductible',
        S('The deductible', 'Under our fleet policy, the most a renter pays for damage to the car is the deductible: 2,500 dollars, plus a 75 dollar administration fee for a claim.', money('Damage', [['Deductible', '$2,500'], ['Claim administration fee', '$75']])),
        S('How damage is billed', 'Damage under the deductible is billed from the deposit first, then the card on file. Only an Admin bills damage or keeps a deposit, always with the photos.', steps('Billing damage', ['Photos at pickup and return compared', 'Admin decides, with the photos', 'Deposit first, then the card on file', 'More than $2,500 goes through a claim'])),
        S('Reporting', 'An accident or damage is reported within 48 hours. While the renter has the car, Report a problem on their booking calls roadside help or messages us.', rule('Report within 48 hours', 'Report a problem on the booking, or call us.', 'warn')),
        S('"The scratch was already there"', 'Stay calm. The handover photos settle it, so point to them.', chat(['renter', 'That scratch was there before!'], ['you', 'Let\'s check together. Every handover has 19 timed photos and a damage diagram. If it is in the pickup photos, it is not yours. If not, an Admin reviews it and tells you before anything is charged.']))
      )
    ],
    quiz: [
      Q('A renter cancels a standard booking 30 hours before pickup, booked a week ago. What is refunded?', ['95%', '75%', '50%', 'Nothing'], 2, '24 to 48 hours before pickup gives 50% back.'),
      Q('What does a late return cost?', ['Nothing', '$25 an hour after a 30 minute grace', 'A full day from the first minute', '$100 flat'], 1, 'There is a 30 minute grace, then $25 an hour.'),
      Q('The car comes back with less fuel. What is charged?', ['Nothing', 'The pump price plus 25%, and a $25 service fee', 'A flat $50', 'The deposit is kept'], 1, 'Fuel short is the pump price plus 25%, plus a $25 service fee, unless a full tank was prepaid.'),
      Q('A toll notice arrives. What does the renter pay?', ['Nothing', 'The amount plus $15', 'The amount plus $40', 'Only our fee'], 1, 'A toll is the amount plus a $15 fee; a ticket is the amount plus $40.'),
      Q('What is the most a renter pays for damage under our fleet policy?', ['$500', '$1,000', 'The $2,500 deductible, plus $75 for a claim', 'The full repair'], 2, 'The deductible is $2,500, plus a $75 administration fee for a claim.'),
      Q('Who decides to bill damage or keep a deposit?', ['Anyone at the return', 'An Admin, with the photos', 'The renter', 'The owner'], 1, 'Only an Admin bills damage or keeps a deposit, with the photos.'),
      Q('Within how long must an accident be reported?', ['48 hours', '7 days', '30 days', 'At the return'], 0, 'Accidents and damage are reported within 48 hours.')
    ]
  }
];
