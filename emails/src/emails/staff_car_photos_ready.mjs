import { hero, h, vehicle, facts, button, list } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_car_photos_ready',
  audience: 'staff_va_fleet',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.owners,
  digest: true,
  digestSlot: 'next',
  trigger: 'Release 48 AN (3150): every view of the photo standard is made for a car (studio renders, the side profile the cover) and they went live at once, with no approval step. Queued for the next Fleet digest so a person can look them over. Once per set of renders.',
  timing: 'Next digest',
  subject: 'Studio photos live: {{vehicle_name}}',
  preheader: '{{render_count}} renders went live, the side profile first. Look them over and make any again.',
  ref: 'Studio photos',
  body: [
    hero('Studio photos', 'New renders are live', 'The studio renders of the {{vehicle_name}} are on its page now, the side profile first, then its own photos.'),
    vehicle(),
    facts(
      ['Renders live', '{{render_count}}'],
      ['Owner', '{{owner_name}}'],
    ),
    button('Open the car', '@va_fleet_vehicle'),
    h('Look them over'),
    list(
      'Same colour, wheels and trim as the car\'s own photos.',
      'The side profile faces left, like every other car.',
      'Anything off: Studio photos, Make again, or Take off the site. The next render becomes the cover.',
    ),
  ],
  sample: { vehicle_name: '2023 Toyota RAV4 XLE', vehicle_id: 'v-3f81c2', render_count: '9', owner_name: 'Daniel Okafor' },
};
