// The academy section of release 35, part D (migration 1828, supabase/seed/1828_gen_academy.mjs): breaks and the activity
// tracker for customer service, Fleet and Finance, written from the guide chapter va/your-workday. No vendor names.
import { L, Q, S, list, rule, steps, title } from './helpers.mjs';

export const SECTIONS = [
  {
    slug: 'new-r35-breaks-activity', title: 'Breaks and activity',
    blurb: 'Start and end your breaks next to the clock. While you are clocked in, the portal notes only that you are active.',
    paths: ['cs', 'fleet', 'finance'],
    guides: ['va/your-workday'],
    lessons: [
      L('Your breaks',
        S('No fixed length', 'Take a break when you need one. Press Start break next to the clock, and End break when you are back.', title('Breaks', 'At your discretion')),
        S('Every break is kept', 'Each break keeps its start, its end and a reason if you give one. You see them on My hours.', steps('A break', ['Press Start break (a reason is optional)', 'The timer runs on your home page', 'Press End break when you are back'])),
        S('A reminder', 'A break still open after 30 minutes reminds you, and the Admins see it. Clocking out ends a break by itself.', rule('Forgot to end it?', 'You get a reminder after 30 minutes. Only an Admin can change a break afterwards, with a reason.', 'warn'))),
      L('Activity while clocked in',
        S('What is noted', 'While you are clocked in and not on a break, the portal notes that you are active: a click, a key, a scroll or switching to its tab.', list('Counted as active', ['A click, a key or a scroll in the portal', 'Anything you do in the portal', 'A phone call you take or make', 'The townhall'])),
        S('What is never noted', 'It never records what you type, which pages you open, or your screen.', rule('Only the fact', 'No keystrokes, no pages, no screenshots.')),
        S('Keep the tab open', 'Keep the portal open while you work. After a few minutes without activity it asks Still there? Tap anywhere to carry on. Nothing is counted outside your scheduled hours.', rule('A hidden tab', 'A tab nobody touches counts as inactive, and the Admins are told after 10 minutes.', 'warn')))
    ],
    quiz: [
      Q('How long can a break be?', ['Exactly 15 minutes', 'There is no fixed length', 'One hour a day', 'Only at lunch time'], 1, 'Breaks are at your discretion; each one is kept with its start and end.'),
      Q('What does the portal record while you are clocked in?', ['What you type', 'The pages you open', 'Only the fact that you are active', 'Screenshots'], 2, 'Only the fact of activity: never keys, pages or screens.'),
      Q('You forgot to press End break. What happens?', ['Nothing', 'After 30 minutes you get a reminder and the Admins see it', 'Your day is deleted', 'You are clocked out at once'], 1, 'A break open past 30 minutes reminds you; clocking out also ends it.'),
      Q('Who can change a break after it has ended?', ['Anyone on the team', 'You, at any time', 'Only an Admin, with a reason', 'Nobody, ever'], 2, 'Only an Admin can change a break afterwards, and the reason is kept.'),
      Q('Which of these counts as active?', ['A hidden tab nobody touches', 'A phone call you take', 'Being clocked out', 'Time after your scheduled hours'], 1, 'Calls you take or make and the townhall count as active.')
    ]
  }
];
