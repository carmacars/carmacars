import { hero, p, small, h, button, list, when, each, notice } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_application_info_requested',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'An Admin presses "Ask for something" on an owner application (Admin > Owners and partners > Applications) and chooses what is needed. The owner also sees it as a task in the owner portal until they answer. One email per request.',
  timing: 'Immediate',
  subject: 'We need a little more for application {{application_number}}',
  preheader: 'A few items for your {{vehicle_name}}, then we can send your terms.',
  ref: 'Owner application {{application_number}}',
  body: [
    hero('One more step', 'We need a little more, {{first_name}}', 'Before we can approve your application for the {{vehicle_name}}, please send us the items below.'),
    h('What we need'),
    each('requested_items', [p('- {{item}}')]),
    when('has_message', [notice('info', 'A note from our team', '{{request_message}}')]),
    button('Answer in my owner portal', '@owner'),
    small('Upload documents from your owner portal, or reply to this email with them attached. We review your answer within 1 business day.'),
  ],
  sample: {
    application_number: 'OA-1001', vehicle_name: '2023 Toyota RAV4 XLE', requested_items: [{ item: 'The vehicle\'s ownership permit' }, { item: 'Your current insurance pink slip' }],
    has_message: true, request_message: 'The ownership permit you sent is cut off at the bottom. A full photo is fine.',
  },
};
