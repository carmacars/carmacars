// The fields of each official ServiceOntario PDF that are deliberately not filled (Release 21b, item 8: the form-completeness
// audit), with the reason. Every field of the publisher's PDF is either mapped (maps.generated.json, migration 0122) or
// matched here: official.test.ts fails on a field that is neither, on a rule that matches no field, and on a rule that
// matches a mapped field. The owner's rule (October 23, 2026) stands: only empty text boxes are filled; checkboxes,
// drop-downs the counter chooses, signatures and their dates are done in person.
// Relative imports with their extension: the unit tests run this file in Node directly.
import type { FieldType } from './fill.ts';

export interface NotMapped { match: RegExp; type?: FieldType; reason: string }
const BUTTON: NotMapped = { match: /./, type: 'button', reason: 'A button of the PDF (print, save, reset), not a value.' };
const CHECKBOX: NotMapped = { match: /./, type: 'checkbox', reason: 'Ticked at the counter: a checkbox the person at the counter decides.' };
const SIGNED = 'Signed in ink at the counter, with its date.';
const MAILING = 'Mailing address: the same as the address above, so left empty.';

export const NOT_MAPPED: Record<string, NotMapped[]> = {
  'SR-LV-006': [
    BUTTON, CHECKBOX,
    { match: /personalInfo\[0\]\.#subform\[0\]\.#subform\[1\]\.lastName\[1\]$/, reason: 'Sex: asked of new individual plate registrants only.' },
    { match: /personalInfo\[0\]\.(streetName|apt|city|postalCode)\[1\]$/, reason: MAILING },
    { match: /businessInfo\[0\]\.#subform\[3\]\./, reason: 'Section 2 gross weight, axles and seating: commercial vehicles only.' },
    { match: /businessInfo\[0\]\.#subform\[4\]\.#field\[15\]$/, reason: 'Section 2 plates returned for credit: none (the plate on record is attached).' },
    { match: /businessInfo2\[0\]\./, type: 'text', reason: 'Section 3 other registration and the dealer\'s S.S.C. number: not a dealer registration.' },
    { match: /businessInfo3\[0\]\./, reason: 'Section 4 replacement plate or permit: not a replacement.' },
    { match: /businessInfo4\[0\]\./, reason: 'Section 5 CVOR declaration: not a commercial vehicle.' },
    { match: /businessInfo5\[0\]\./, reason: 'Section 6 change of gross weight or seating: not asked.' },
    { match: /businessInfo6\[0\]\.#field\[[12]\]$/, reason: 'Section 7 insurer and policy: the fleet policy, written at the counter.' },
    { match: /businessInfo7\[0\]\.date\[0\]$/, reason: SIGNED },
    { match: /businessInfo8\[0\]\./, reason: 'Office use only.' }
  ],
  'SR-LV-012': [
    BUTTON,
    { match: /\.lastName\[(1|5)\]$/, reason: 'Sex: asked of individual registrants by the counter.' },
    { match: /#subform\[(2|6)\]\.lastName\[(2|6)\]$/, reason: 'Registrant type: office use.' },
    { match: /personalInfo\[0\]\.#subform\[0\]\.#subform\[1\]\.date\[0\]$/, reason: 'Section 1 date of birth: the plate owner is CarmaCars, a corporation.' },
    { match: /businessInfo\[0\]\.#subform\[4\]\.#subform\[5\]\.date\[1\]$/, reason: 'Section 2 second registrant\'s date of birth: CarmaCars, a corporation.' },
    { match: /personalInfo\[0\]\.(streetName|apt|city|postalCode)\[1\]$/, reason: MAILING },
    { match: /(personalInfo\[0\]\.(signature\[0\]|date\[1\])|businessInfo\[0\]\.(signature\[1\]|date\[[23]\]))$/, reason: SIGNED },
    { match: /businessInfo2\[0\]\./, reason: 'Section 3 operating name: no unincorporated name is recorded.' }
  ],
  ON00453: [
    CHECKBOX,
    { match: /\.(ifNo\[0\]\.where|physicallyLocated)\[0\]$/, reason: 'Whether the vehicles are kept at this address: the owner answers.' },
    { match: /\.POBox\[0\]$/, reason: 'Post office box: not used (a street address is required).' },
    { match: /\.province\[0\]$/, reason: 'Province: the form shows Ontario.' },
    { match: /\.sig1\[0\]\.(ScribSignature|signatureImage|date)\[0\]$/, reason: SIGNED },
    { match: /\.instructor\[0\]\./, reason: 'Driving instructor block: not a driving school.' },
    { match: /\.ministryUseOnly\[0\]\./, reason: 'Ministry use only.' }
  ],
  '013-0169': [
    BUTTON,
    { match: /busPoBox\[0\]$/, reason: 'Post office box: not used (a street address is given).' },
    { match: /txt_relationship\[0\]$/, reason: 'The relationship between seller and buyer: the owner writes it in their own words.' }
  ],
  '013-1155': [
    BUTTON,
    { match: /^(cityTown[356]?|countyRegionalMunicipality[2-6]?)$/, reason: 'City or Town words and the county or regional municipality: they depend on the municipality, written by the owner.' },
    { match: /^(date|reasons|detailedReasons)$/, reason: 'The acquisition date and the reasons: the owner writes them.' },
    { match: /^(day|month|year|commissioner)$/, reason: 'Sworn before a commissioner, in person.' }
  ]
};

/** The rule that leaves this field empty, or null. */
export function notMapped(code: string, name: string, type: FieldType): NotMapped | null {
  return (NOT_MAPPED[code] ?? []).find((r) => (r.type ? r.type === type : true) && r.match.test(name)) ?? null;
}
