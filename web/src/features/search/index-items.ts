// The site search (release 28, B4): the public list the browser searches itself, and the ranking. Pure, so the server
// (the list), the browser (the ranking) and the unit tests share it (search.test.ts).

export type Group = 'pages' | 'portals' | 'cars' | 'places' | 'guides' | 'help' | 'records';
export interface Item {
  /** what is shown */ t: string;
  /** the line under it */ s?: string;
  /** where it goes (a path on this site) */ h: string;
  /** the group */ g: Group;
  /** more words it answers to (not shown) */ w?: string;
}

export const GROUP_LABEL: Record<Group, string> = {
  pages: 'Pages', portals: 'Sign in and portals', cars: 'Cars', places: 'Places and services', guides: 'Guides', help: 'Help', records: 'Your records'
};

/** The site's pages, with the words people use for them. */
export const PAGES: Item[] = [
  { t: 'Home', h: '/', g: 'pages', w: 'start main carmacars' },
  { t: 'Fleet: every car', s: 'Dates, prices and photos', h: '/cars', g: 'pages', w: 'cars rent book vehicles inventory available fleet' },
  { t: 'How it works', s: 'Request to book, then pay once the price is confirmed', h: '/how-it-works', g: 'pages', w: 'request booking process steps' },
  { t: 'Delivery', s: 'To your door or the airport', h: '/delivery', g: 'pages', w: 'deliver drop off airport pearson home' },
  { t: 'Chauffeur', s: 'A driver by the hour', h: '/chauffeur', g: 'pages', w: 'driver limo chauffeur' },
  { t: 'Requirements', s: 'Age, licence and coverage', h: '/requirements', g: 'pages', w: 'age licence license insurance young driver documents' },
  { t: 'Credit card rental coverage', h: '/credit-card-rental-coverage', g: 'pages', w: 'insurance cdw card coverage' },
  { t: 'List your car', s: 'The owner program', h: '/list-your-car', g: 'pages', w: 'owner earn money list my car host program management' },
  { t: 'Apply to list your car', s: 'The owner application', h: '/list-your-car/apply', g: 'pages', w: 'owner apply application signup' },
  { t: 'Owner earnings calculator', s: 'What your car could earn', h: '/list-your-car#earnings', g: 'pages', w: 'owner earnings estimate calculator income' },
  { t: 'FAQ', s: 'Straight answers', h: '/faq', g: 'help', w: 'questions help answers deposit payment' },
  { t: 'Contact us', s: 'Phone, text, email or chat', h: '/contact', g: 'help', w: 'phone email call text support help contact' },
  { t: 'Cancellation policy', h: '/cancellation-policy', g: 'help', w: 'cancel refund' },
  { t: 'Terms', h: '/terms', g: 'help', w: 'terms conditions rental agreement legal' },
  { t: 'Privacy', h: '/privacy', g: 'help', w: 'privacy data personal information' },
  { t: 'About CarmaCars', h: '/about', g: 'pages', w: 'about company team' },
  { t: 'Careers', s: 'Jobs at CarmaCars', h: '/careers', g: 'pages', w: 'jobs work hiring career apply' },
  { t: 'Investors', s: 'Invest in CarmaCars', h: '/investors', g: 'pages', w: 'invest investment investor returns' },
  { t: 'Body shops', s: 'Partner with us', h: '/partners/body-shops', g: 'pages', w: 'partner body shop collision repair referral' },
  { t: 'Tow trucks', s: 'Partner with us', h: '/partners/tow-trucks', g: 'pages', w: 'partner tow towing referral' },
  { t: 'Detailing', h: '/detailing', g: 'pages', w: 'detail wash cleaning' },
  { t: 'Body shop', h: '/body-shop', g: 'pages', w: 'repair collision' },
  { t: 'Cars for sale', h: '/buy', g: 'pages', w: 'buy purchase sale used' },
  { t: 'Car makes', h: '/makes', g: 'places', w: 'brands makes models' },
  { t: 'Places we deliver', h: '/places', g: 'places', w: 'locations cities areas neighbourhoods' },
  { t: 'Guides', s: 'Renting in Toronto, tolls, airports', h: '/guides', g: 'guides', w: 'articles blog help guides' }
];

/** The portals' doors: a renter, an owner, an investor, a partner or staff finds where to sign in. */
export const PORTALS: Item[] = [
  { t: 'Sign in', s: 'Your account, any portal', h: '/sign-in', g: 'portals', w: 'login log in account password' },
  { t: 'Create an account', h: '/create-account', g: 'portals', w: 'sign up register new account' },
  { t: 'Renter account sign in', s: 'Your trips and bookings', h: '/account', g: 'portals', w: 'renter my booking trips account login' },
  { t: 'Owner portal sign in', s: 'Your cars, statements and payouts', h: '/owner', g: 'portals', w: 'owner host login portal payouts statements' },
  { t: 'Investor portal sign in', s: 'Your investment and statements', h: '/investor', g: 'portals', w: 'investor login portal returns statements' },
  { t: 'Partner portal', s: 'Body shops and tow trucks: open the link in your partner email', h: '/partners/body-shops', g: 'portals', w: 'partner login sign in portal referral body shop tow' },
  { t: 'Staff portal sign in', s: 'For the CarmaCars team', h: '/staff', g: 'portals', w: 'staff employee team login va field' },
  { t: 'Forgot your password', h: '/reset-password', g: 'portals', w: 'reset password forgot' }
];

/** Lower case, accents and punctuation off, for matching. */
export const norm = (s: string) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, ' ').trim();

/** The items that match every word typed, best first: a title that starts with the query, then a title word that does,
 *  then a title containing it, then the other words. At most `max`. */
export function rankItems(items: Item[], query: string, max = 20): Item[] {
  const q = norm(query);
  if (!q) return [];
  const words = q.split(' ');
  const scored: Array<[number, number, Item]> = [];
  items.forEach((it, i) => {
    const t = norm(it.t);
    const all = `${t} ${norm(it.s ?? '')} ${norm(it.w ?? '')}`;
    if (!words.every((w) => all.includes(w))) return;
    let score = 0;
    if (t.startsWith(q)) score += 100;
    else if ((' ' + t).includes(' ' + q)) score += 60;
    else if (t.includes(q)) score += 40;
    for (const w of words) { if ((' ' + t).includes(' ' + w)) score += 10; else if (t.includes(w)) score += 5; }
    if (it.g === 'portals' && /sign|login|log in|portal/.test(q)) score += 15;
    scored.push([score, i, it]);
  });
  return scored.sort((a, b) => b[0] - a[0] || a[1] - b[1]).slice(0, max).map((x) => x[2]);
}
