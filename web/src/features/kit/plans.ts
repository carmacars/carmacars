// The shape of each page type for the writing kit: its sections in order (a group of sections may swap places by the
// page's hash), the slots of each paragraph, the questions, and the word range. A section runs only when its
// condition holds; a sentence whose facts are missing is left out; prio decides what goes first when a page runs long.
import type { PageKind } from './facts.ts';

export interface SectionPlan {
  id: string;
  /** the heading's bank */
  h: string;
  /** each paragraph: the banks of its sentences, in order */
  paras: string[][];
  /** tags that must hold (engine condition syntax) */
  when?: string;
  /** higher stays longer when a page runs over its word range */
  prio: number;
  /** sections with the same group number next to each other may swap places */
  group?: number;
}
export interface KindPlan { words: [number, number]; sections: SectionPlan[]; faq: string[] }

const BOOK: SectionPlan = { id: 'book', h: 'c.h.book', paras: [['c.book.request', 'c.book.offer', 'c.book.pay'], ['c.book.calendar', 'c.book.long', 'c.book.notice']], prio: 60, group: 3 };
const NEED: SectionPlan = { id: 'need', h: 'c.h.need', paras: [['c.need.age', 'c.need.young', 'c.need.card'], ['c.need.protect', 'c.need.deposit', 'c.need.check']], prio: 50, group: 3 };
const CLOSE: SectionPlan = { id: 'close', h: 'c.h.close', paras: [['c.close']], prio: 30 };
const closeWith = (bank: string): SectionPlan => ({ ...CLOSE, paras: [[bank]] });
const FAR_SHORT: SectionPlan = { id: 'far', h: 'c.h.far', paras: [['c.far.base', 'c.far.km'], ['k.far', 'k.far', 'c.far.ask', 'c.far.usd']], when: 'far local', prio: 95 };
const FAR: SectionPlan = { id: 'far', h: 'c.h.far', paras: [['c.far.base', 'c.far.km'], ['c.far.what', 'c.far.fly', 'c.far.border', 'c.far.ask', 'c.far.usd']], when: 'far local', prio: 95 };
const LOCAL: SectionPlan = { id: 'local', h: 'c.h.local', paras: [['c.local.toronto', 'c.local.gta', 'c.local.parent', 'c.local.nearby', 'c.local.landmarks'], ['c.local.airport', 'c.local.toraero', 'c.local.winter']], when: 'local', prio: 70, group: 2 };
const LOCAL_SERVED: SectionPlan = { ...LOCAL, when: 'local served' };
const DELIVERY: SectionPlan = { id: 'delivery', h: 'c.h.del', paras: [['c.del.near', 'c.del.fee', 'c.del.nofee'], ['c.del.pickup', 'c.del.handover', 'c.del.airport']], when: 'served local', prio: 80, group: 2 };
const TRIPS: SectionPlan = { id: 'trips', h: 'c.h.trips', paras: [['c.trip.one', 'c.trip.two', 'c.trip.km', 'c.trip.border']], when: 'trips', prio: 35, group: 2 };

export const PLANS: Record<PageKind, KindPlan> = {
  'hub-rental': {
    words: [350, 600],
    sections: [
      { id: 'intro', h: 'hr.h.intro', paras: [['hr.intro.open', 'hr.intro.term', 'hr.intro.more']], prio: 100 },
      FAR,
      { id: 'why', h: 'hr.h.why', paras: [['hr.why.family', 'hr.why.family', 'hr.why.general', 'hr.why.general']], prio: 75, group: 2 },
      DELIVERY, LOCAL, TRIPS,
      { id: 'who', h: 'hr.h.who', paras: [['hr.who', 'hr.who']], prio: 40, group: 2 },
      BOOK, NEED, CLOSE
    ],
    faq: ['hr.faq.family', 'hr.faq.pay', 'hr.faq.licence', 'hr.faq.deposit', 'hr.faq.long']
  },
  'hub-request': {
    words: [250, 450],
    sections: [
      { id: 'intro', h: 'hq.h.intro', paras: [['hq.intro.open', 'hr.intro.term']], prio: 100 },
      { id: 'how', h: 'c.h.book', paras: [['hq.how', 'hq.how', 'hq.how', 'hq.how']], prio: 90 },
      { id: 'vehicles', h: 'hq.h.vehicles', paras: [['hq.vehicles', 'hq.vehicles', 'hq.self']], prio: 70 },
      { id: 'when', h: 'hq.h.when', paras: [['hq.when', 'hq.when', 'hq.when']], prio: 60, group: 4 },
      { id: 'tip', h: 'hq.h.tip', paras: [['hq.tip', 'hq.tip', 'hq.tip']], prio: 55, group: 4 },
      FAR_SHORT, LOCAL_SERVED, closeWith('hq.close')
    ],
    faq: []
  },
  'hub-wide': {
    words: [250, 450],
    sections: [
      { id: 'intro', h: 'hw.h.intro', paras: [['hw.intro.open', 'hw.within', 'hr.intro.term']], prio: 100 },
      { id: 'reach', h: 'c.h.del', paras: [['hw.reach', 'hw.reach', 'c.del.pickup', 'c.del.airport']], prio: 90 },
      { id: 'why', h: 'hr.h.why', paras: [['hr.why.family', 'hr.why.general', 'hr.why.general']], prio: 60, group: 2 },
      BOOK, NEED, CLOSE
    ],
    faq: ['hr.faq.pay', 'hr.faq.licence']
  },
  'hub-sale': {
    words: [250, 450],
    sections: [
      { id: 'intro', h: 'hs.h.intro', paras: [['hs.intro.open', 'hs.family', 'hs.family']], prio: 100 },
      { id: 'rent', h: 'hs.h.rent', paras: [['hs.rent', 'hs.rent', 'hs.rent', 'hs.served']], prio: 90 },
      { id: 'check', h: 'hs.h.check', paras: [['hs.check', 'hs.check', 'hs.check', 'hs.check']], prio: 70 },
      { id: 'while', h: 'hs.h.while', paras: [['hs.while', 'hs.while', 'hs.while']], prio: 55 },
      FAR_SHORT, LOCAL_SERVED, closeWith('hs.close')
    ],
    faq: []
  },
  'hub-detailing': {
    words: [300, 500],
    sections: [
      { id: 'intro', h: 'hd.h.intro', paras: [['hd.intro.open', 'hd.what', 'hd.family', 'hd.family']], prio: 100 },
      { id: 'request', h: 'hd.h.request', paras: [['hd.request', 'hd.request', 'hd.price', 'hd.noprice', 'hd.request']], prio: 90 },
      { id: 'rent', h: 'hd.h.rent', paras: [['hd.rent', 'hd.rent', 'c.del.pickup']], when: 'served|wide', prio: 80 },
      { id: 'cost', h: 'hd.h.cost', paras: [['hd.cost', 'hd.cost', 'hd.cost']], prio: 70, group: 4 },
      { id: 'time', h: 'hd.h.time', paras: [['hd.time', 'hd.time', 'hd.time']], prio: 65, group: 4 },
      { id: 'after', h: 'hd.h.after', paras: [['hd.after', 'hd.after']], prio: 50, group: 4 },
      { id: 'bring', h: 'hd.h.bring', paras: [['hd.bring', 'hd.bring', 'hd.bring']], prio: 48, group: 4 },
      FAR_SHORT, LOCAL_SERVED, closeWith('hd.close')
    ],
    faq: []
  },
  'hub-bodyshop': {
    words: [300, 500],
    sections: [
      { id: 'intro', h: 'hd.h.intro', paras: [['hd.intro.open', 'hd.what', 'hd.family', 'hd.family']], prio: 100 },
      { id: 'request', h: 'hd.h.request', paras: [['hd.request', 'hd.request', 'hd.price', 'hd.noprice', 'hd.request']], prio: 90 },
      { id: 'rent', h: 'hd.h.rent', paras: [['hd.rent', 'hd.rent', 'c.del.pickup']], when: 'served|wide', prio: 80 },
      { id: 'cost', h: 'hd.h.cost', paras: [['hd.cost', 'hd.cost', 'hd.cost']], prio: 70, group: 4 },
      { id: 'time', h: 'hd.h.time', paras: [['hd.time', 'hd.time', 'hd.time']], prio: 65, group: 4 },
      { id: 'after', h: 'hd.h.after', paras: [['hd.after', 'hd.after']], prio: 50, group: 4 },
      { id: 'bring', h: 'hd.h.bring', paras: [['hd.bring', 'hd.bring', 'hd.bring']], prio: 48, group: 4 },
      FAR_SHORT, LOCAL_SERVED, closeWith('hd.close')
    ],
    faq: []
  },
  'hub-auto': {
    words: [250, 450],
    sections: [
      { id: 'intro', h: 'ha.h.intro', paras: [['ha.intro.open', 'ha.what', 'ha.family']], prio: 100 },
      { id: 'how', h: 'ha.h.how', paras: [['ha.how', 'ha.how', 'ha.how', 'ha.how']], prio: 95 },
      { id: 'rent', h: 'ha.h.rent', paras: [['ha.rent', 'ha.rent', 'c.del.pickup']], when: 'served|wide', prio: 80 },
      { id: 'ask', h: 'ha.h.ask', paras: [['ha.ask', 'ha.ask', 'ha.ask', 'ha.ask']], prio: 60, group: 4 },
      { id: 'tips', h: 'ta.h.tips', paras: [['ta.tip', 'ta.tip', 'ta.tip']], prio: 45, group: 4 },
      FAR_SHORT, LOCAL_SERVED, closeWith('ha.close')
    ],
    faq: []
  },

  // ---------------------------------------------------------------- vehicle pages
  'car-make': {
    words: [300, 500],
    sections: [
      { id: 'intro', h: 'vm.h.intro', paras: [['vm.intro', 'vm.models', 'vm.ev', 'vm.ev'], ['vm.how', 'vm.how']], prio: 100 },
      { id: 'choose', h: 'vm.h.choose', paras: [['vm.choose', 'vm.choose', 'vm.choose']], prio: 70 },
      { id: 'rent', h: 'v.h.rent', paras: [['v.rent', 'v.rent', 'v.rent', 'v.del']], prio: 90 },
      { ...BOOK, group: 3 }, { ...NEED, group: 3 }, CLOSE
    ],
    faq: []
  },
  'car-model': {
    words: [300, 550],
    sections: [
      { id: 'intro', h: 'v.h.intro', paras: [['v.intro.model', 'v.intro.best', 'v.intro.trims']], prio: 100 },
      { id: 'like', h: 'v.h.like', paras: [['v.like.body', 'v.like.more', 'v.like.seats']], prio: 80, group: 2 },
      { id: 'who', h: 'v.h.who', paras: [['v.who', 'v.who', 'v.who']], prio: 70, group: 2 },
      { id: 'rent', h: 'v.h.rent', paras: [['v.rent', 'v.rent', 'v.rent', 'v.del']], prio: 90 },
      BOOK, NEED, CLOSE
    ],
    faq: []
  },
  'car-year': {
    words: [350, 600],
    sections: [
      { id: 'intro', h: 'v.h.intro', paras: [['v.intro.year', 'v.intro.trims']], prio: 100 },
      { id: 'spec', h: 'v.h.spec', paras: [['v.spec.engine', 'v.spec.fuel', 'v.spec.drive', 'v.spec.trans'], ['v.spec.use', 'v.spec.cityhwy', 'v.spec.kwh', 'v.spec.range', 'v.spec.cost', 'v.spec.premium', 'v.spec.nospecs']], prio: 95 },
      { id: 'like', h: 'v.h.like', paras: [['v.like.body', 'v.like.cargo', 'v.like.seats']], prio: 75, group: 2 },
      { id: 'who', h: 'v.h.who', paras: [['v.who', 'v.who', 'v.who']], prio: 65, group: 2 },
      { id: 'trip', h: 'v.h.trip', paras: [['v.trip', 'v.trip', 'v.trip']], prio: 45, group: 2 },
      { id: 'rent', h: 'v.h.rent', paras: [['v.rent', 'v.rent', 'v.rent', 'v.del']], prio: 90 },
      BOOK, NEED, CLOSE
    ],
    faq: []
  },
  'car-trim': {
    words: [400, 600],
    sections: [
      { id: 'intro', h: 'v.h.intro', paras: [['v.intro.trim', 'v.intro.trim']], prio: 100 },
      { id: 'spec', h: 'v.h.spec', paras: [['v.spec.engine', 'v.spec.fuel', 'v.spec.drive', 'v.spec.trans'], ['v.spec.use', 'v.spec.cityhwy', 'v.spec.kwh', 'v.spec.range', 'v.spec.charge', 'v.spec.cost', 'v.spec.premium', 'v.spec.mpg', 'v.spec.nospecs']], prio: 95 },
      { id: 'like', h: 'v.h.like', paras: [['v.like.body', 'v.like.size', 'v.like.cargo', 'v.like.seats', 'v.like.weight']], prio: 80, group: 2 },
      { id: 'who', h: 'v.h.who', paras: [['v.who', 'v.who', 'v.who']], prio: 65, group: 2 },
      { id: 'trip', h: 'v.h.trip', paras: [['v.trip', 'v.trip', 'v.trip']], prio: 45, group: 2 },
      { id: 'rent', h: 'v.h.rent', paras: [['v.rent', 'v.rent', 'v.rent', 'v.del']], prio: 90 },
      BOOK, NEED, CLOSE
    ],
    faq: []
  },
  'car-tier': {
    words: [350, 600],
    sections: [
      { id: 'intro', h: 'v.h.intro', paras: [['v.intro.trim', 'v.intro.trim']], prio: 100 },
      { id: 'city', h: 'vc.h.city', paras: [['vc.city', 'vc.city', 'vc.city', 'vc.city'], ['c.local.nearby', 'c.local.airport', 'c.local.winter']], when: 'city', prio: 97 },
      { id: 'colour', h: 'vc.h.colour', paras: [['vc.colour', 'vc.colour', 'vc.colour']], when: 'colour', prio: 96 },
      { id: 'spec', h: 'v.h.spec', paras: [['v.spec.engine', 'v.spec.fuel', 'v.spec.drive'], ['v.spec.use', 'v.spec.kwh', 'v.spec.range', 'v.spec.cost', 'v.spec.nospecs']], prio: 85 },
      { id: 'like', h: 'v.h.like', paras: [['v.like.body', 'v.like.size', 'v.like.cargo', 'v.like.seats']], prio: 70, group: 2 },
      { id: 'who', h: 'v.h.who', paras: [['v.who', 'v.who']], prio: 60, group: 2 },
      { id: 'rent', h: 'v.h.rent', paras: [['v.rent', 'v.rent', 'v.rent', 'v.del']], prio: 90 },
      BOOK, NEED, CLOSE
    ],
    faq: []
  },

  // ---------------------------------------------------------------- twins
  'twin-rental': {
    words: [350, 600],
    sections: [
      { id: 'intro', h: 'tr.h.intro', paras: [['tr.intro', 'tr.family', 'tr.family']], prio: 100 },
      { id: 'city', h: 'vc.h.city', paras: [['vc.city', 'vc.city', 'vc.city'], ['c.local.nearby', 'c.local.airport']], when: 'city', prio: 96 },
      { id: 'spec', h: 'v.h.spec', paras: [['v.spec.engine', 'v.spec.fuel', 'v.spec.drive'], ['v.spec.use', 'v.spec.kwh', 'v.spec.range', 'v.spec.cost', 'v.spec.nospecs']], prio: 85 },
      { id: 'like', h: 'v.h.like', paras: [['v.like.body', 'v.like.size', 'v.like.cargo', 'v.like.seats']], prio: 70, group: 2 },
      { id: 'who', h: 'v.h.who', paras: [['v.who', 'v.who']], prio: 60, group: 2 },
      { id: 'rent', h: 'v.h.rent', paras: [['v.rent', 'v.rent', 'v.rent', 'v.del']], prio: 90 },
      BOOK, NEED, CLOSE
    ],
    faq: []
  },
  'twin-sale': {
    words: [300, 550],
    sections: [
      { id: 'intro', h: 'ts.h.intro', paras: [['ts.intro.sale', 'ts.finance', 'ts.intro']], prio: 100 },
      { id: 'check', h: 'ts.h.check', paras: [['ts.check', 'ts.check', 'ts.check', 'ts.check']], prio: 92 },
      { id: 'spec', h: 'v.h.spec', paras: [['v.spec.engine', 'v.spec.fuel', 'v.spec.drive'], ['v.spec.use', 'v.spec.kwh', 'v.spec.range', 'v.spec.cost', 'v.spec.year', 'v.spec.nospecs']], prio: 85 },
      { id: 'like', h: 'v.h.like', paras: [['v.like.body', 'v.like.size', 'v.like.cargo']], prio: 70, group: 2 },
      { id: 'who', h: 'v.h.who', paras: [['v.who', 'v.who']], prio: 60, group: 2 },
      { id: 'rent', h: 'ts.h.rent', paras: [['ts.rent', 'ts.rent', 'ts.rent']], prio: 90 },
      { id: 'money', h: 'ts.h.money', paras: [['ts.money', 'ts.money', 'ts.money']], prio: 58, group: 2 },
      { id: 'choose', h: 'ts.h.choose', paras: [['ts.choose', 'ts.choose', 'ts.choose']], prio: 52, group: 2 },
      { id: 'city', h: 'vc.h.city', paras: [['vc.city', 'vc.city']], when: 'city', prio: 50 },
      closeWith('hs.close')
    ],
    faq: []
  },
  'twin-detailing': {
    words: [300, 500],
    sections: [
      { id: 'intro', h: 'td.h.intro', paras: [['td.intro', 'hd.what', 'hd.family', 'hd.family']], prio: 100 },
      { id: 'car', h: 'td.h.car', paras: [['td.car', 'td.car', 'td.car', 'v.like.size']], prio: 90 },
      { id: 'request', h: 'hd.h.request', paras: [['td.request', 'td.request', 'td.request']], prio: 85 },
      { id: 'rent', h: 'hd.h.rent', paras: [['td.rent', 'td.rent', 'v.del']], when: '!far', prio: 80 },
      { id: 'cost', h: 'hd.h.cost', paras: [['hd.cost', 'hd.cost', 'hd.cost']], prio: 70, group: 4 },
      { id: 'time', h: 'hd.h.time', paras: [['hd.time', 'hd.time']], prio: 65, group: 4 },
      { id: 'after', h: 'hd.h.after', paras: [['hd.after', 'hd.after']], prio: 50, group: 4 },
      { id: 'bring', h: 'hd.h.bring', paras: [['hd.bring', 'hd.bring', 'hd.bring']], prio: 48, group: 4 },
      { id: 'city', h: 'vc.h.city', paras: [['vc.city', 'vc.city']], when: 'city', prio: 60 },
      closeWith('hd.close')
    ],
    faq: []
  },
  'twin-bodyshop': {
    words: [300, 500],
    sections: [
      { id: 'intro', h: 'td.h.intro', paras: [['td.intro', 'hd.what', 'hd.family', 'hd.family']], prio: 100 },
      { id: 'car', h: 'td.h.car', paras: [['td.car', 'td.car', 'v.like.size', 'tb.recall']], prio: 90 },
      { id: 'request', h: 'hd.h.request', paras: [['td.request', 'td.request', 'td.request']], prio: 85 },
      { id: 'rent', h: 'hd.h.rent', paras: [['td.rent', 'td.rent', 'v.del']], when: '!far', prio: 80 },
      { id: 'cost', h: 'hd.h.cost', paras: [['hd.cost', 'hd.cost', 'hd.cost']], prio: 70, group: 4 },
      { id: 'time', h: 'hd.h.time', paras: [['hd.time', 'hd.time']], prio: 65, group: 4 },
      { id: 'after', h: 'hd.h.after', paras: [['hd.after', 'hd.after']], prio: 50, group: 4 },
      { id: 'bring', h: 'hd.h.bring', paras: [['hd.bring', 'hd.bring', 'hd.bring']], prio: 48, group: 4 },
      { id: 'city', h: 'vc.h.city', paras: [['vc.city', 'vc.city']], when: 'city', prio: 60 },
      closeWith('hd.close')
    ],
    faq: []
  },
  'twin-auto': {
    words: [250, 450],
    sections: [
      { id: 'intro', h: 'ta.h.intro', paras: [['ta.intro', 'ha.what', 'ha.family']], prio: 100 },
      { id: 'car', h: 'ta.h.car', paras: [['ta.car', 'ta.car', 'ta.car', 'v.spec.engine']], prio: 92 },
      { id: 'how', h: 'ha.h.how', paras: [['ta.how', 'ta.how', 'ta.how']], prio: 90 },
      { id: 'rent', h: 'ha.h.rent', paras: [['ta.rent', 'ta.rent', 'v.del']], when: '!far', prio: 80 },
      { id: 'ask', h: 'ha.h.ask', paras: [['ha.ask', 'ha.ask', 'ha.ask']], prio: 55, group: 4 },
      { id: 'tips', h: 'ta.h.tips', paras: [['ta.tip', 'ta.tip', 'ta.tip']], prio: 45, group: 4 },
      { id: 'city', h: 'vc.h.city', paras: [['vc.city', 'vc.city']], when: 'city', prio: 60 },
      closeWith('ha.close')
    ],
    faq: []
  }
};
