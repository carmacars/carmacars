import { hero, small, h, vehicle, facts, button, list } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_car_photos_ready',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Release 48 AN (3150): every view of the photo standard is made for the owner\'s car (studio renders from the car\'s own photos, the side profile first) and they are on the car\'s page. Once per set of renders (the dedupe key is the car and the standard). Switch: the notice in Admin > Settings > Notifications (on by default); the owner can mute it.',
  timing: 'Immediate, when the set is live',
  subject: 'Your {{vehicle_name}} has new studio photos',
  preheader: '{{render_count}} studio views are on its page now, the side profile first. Its own photos follow them.',
  ref: 'Studio photos',
  body: [
    hero('Studio photos', 'Your car has new studio photos', 'Hi {{first_name}}, your {{vehicle_name}} now has {{render_count}} studio photos on its page, made from its own photos so every car on CarmaCars is framed the same way.'),
    vehicle(),
    facts(
      ['Studio photos', '{{render_count}}, the side profile first'],
      ['Your own photos', 'Shown after them, on the same background'],
    ),
    button('See your car\'s page', '@owner_vehicle'),
    h('Good to know'),
    list(
      'The page says the first photos are studio renders, so renters are never misled.',
      'Your own photos stay on the page, right after the studio photos.',
      'Something looks wrong, such as the colour or the wheels? Reply to this email and we make it again.',
    ),
    small('You can turn these emails off in your owner portal under Account, Notifications.'),
  ],
  sample: { vehicle_name: '2023 Toyota RAV4 XLE', vehicle_id: 'v-3f81c2', render_count: '9' },
};
