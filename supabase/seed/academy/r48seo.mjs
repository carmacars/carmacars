// The academy section of migration 3233 (release 48, SEO): where a lead came from and duplicate leads. Written from the
// guide chapters it names.
import { L, Q, S, chat, list, rule, steps, title } from './helpers.mjs';

export const SECTIONS = [
  {
    slug: 'new-r48-lead-source-duplicates', title: 'Where a lead came from, and duplicate leads',
    blurb: 'Read the source of a lead (ChatGPT, Google and its search terms, an ad), use it in your first call, and keep one lead per person with Merge.',
    paths: ['cs', 'sales_in_person', 'sales_remote', 'admin'],
    guides: ['va/sales', 'va/customer-service', 'admin/leads-and-sales-claims'],
    lessons: [
      L('Where they came from',
        S('The badge on the card', 'Every lead from the website says where the person came from. The badge on the lead card reads ChatGPT, Google search, Google Ads, Perplexity, Bing or Direct, with the first page they opened.', list('On the card', ['The source badge', 'The search terms, when we have them', 'First page'])),
        S('The card on the lead', 'Open the lead. The card Where they came from lists Came from, Search terms, First page they opened, Referring page and Campaign. A row we do not know is left out.', steps('Read it', ['Open the lead', 'Find Where they came from', 'Read the source and the first page'])),
        S('Google hides the words', 'Google does not send the words a person searched. For a Google visit the card lists the top Google searches that bring people to that first page, from Search Console.', rule('Google', 'You see the page\'s top searches, not this person\'s own words.', 'warn')),
        S('Use it in the call', 'Start from what they were looking for. Someone who landed on the kill switch page wants the tracker. Someone who landed on monthly rentals wants a monthly price.', chat(['app', 'Came from: ChatGPT. First page: /trackers/kill-switch-for-car'], ['you', 'Hi, you were looking at our kill switch. How many cars is it for?']))),
      L('One person, one lead',
        S('It joins by itself', 'A new website form from someone who already has an open lead of the same kind joins that lead by itself, when the email or the phone is the same. The new message shows under Also wrote.', rule('Automatic', 'Same email or phone, an open lead: one lead.', 'ok')),
        S('Merge with one press', 'A card that says possible duplicate: merge opens the lead with the card Possible duplicates. Press Merge. The oldest lead is kept and everything from the other moves to it.', steps('Merge', ['Open the lead', 'Check why it matches', 'Press Merge'])),
        S('Different person', 'Two people can share an email or a phone, like a couple or an office line. Press Different person and the pair is never suggested again.', rule('Not the same', 'Different person keeps them apart for good.', 'warn')),
        S('Renter and owner stay apart', 'A renter lead and an owner lead of the same person are two conversations. They are never merged.', title('Two kinds', 'A renter lead and an owner lead stay separate')))
    ],
    quiz: [
      Q('Where do you see that a lead came from ChatGPT?', ['Nowhere', 'The badge on the lead card and the card Where they came from on the lead', 'Only in the audit log', 'In the renter\'s profile'], 1, 'The card badge and the lead\'s own card both say it.'),
      Q('A lead came from Google search and shows no search terms of its own. What does the card list instead?', ['Nothing', 'The top Google searches that bring people to the first page they opened', 'The person\'s browsing history', 'A guess'], 1, 'Google does not send the words, so the page\'s top Search Console searches are shown.'),
      Q('The same person sends the contact form twice in one day with the same email. What happens?', ['Two leads and two calls', 'The second joins the open lead by itself', 'The second is deleted', 'Both are closed'], 1, 'A new form joins the person\'s open lead; its message shows under Also wrote.'),
      Q('You press Merge on a duplicate. Which lead is kept?', ['The newest', 'The oldest, with everything from the other moved to it', 'Neither', 'The one with the longer message'], 1, 'The oldest is kept; nothing is deleted.'),
      Q('A couple share one email and each wants a different car. What do you press?', ['Merge', 'Different person', 'Mark handled', 'Spam'], 1, 'Different person keeps the two leads apart and stops the suggestion.'),
      Q('Someone has a renter lead and also asks about listing their car. Are the two merged?', ['Yes, always', 'No: a renter lead and an owner lead stay apart', 'Only by an Admin', 'Only on Fridays'], 1, 'They are different kinds of customer and different conversations.')
    ]
  }
];
