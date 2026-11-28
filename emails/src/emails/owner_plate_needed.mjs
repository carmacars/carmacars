import { hero, p, small, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_plate_needed',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'The plate after registration (R51, migration 5212, REQ-141): an owner\'s car is with CarmaCars without a real plate on file (empty or a placeholder such as XXXXXXXX), for example a car applied for before it was registered. The application never asks the plate. Once per car; Fleet gets the To do "Plate needed" at the same moment.',
  timing: 'Immediate',
  subject: 'Add the plate of your {{vehicle_name}}',
  preheader: 'Once the car is registered, add its plate in your portal. About a minute.',
  ref: 'Plate',
  body: [
    hero('One step for your car', 'Add the plate once it is registered', 'Hi {{first_name}}, we do not have the plate of your {{vehicle_name}} yet. Once the car is registered, add the plate in your owner portal.'),
    button('Add the plate', '{{plate_url}}'),
    p('We need the plate before the car is listed on the website or handed to a renter. Everything else carries on in the meantime.'),
    small('Questions? Reply to this email.'),
  ],
  sample: { vehicle_name: '2021 Toyota Camry', plate_url: 'https://carmacars.ca/owner/vehicles/00000000-0000-4000-8000-000000000001#plate' },
};
