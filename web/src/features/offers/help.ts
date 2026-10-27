// the fees a line may be added for, and what each line of the price means (the (i) beside it, 0132)
export const FEE_LABEL: Record<string, string> = { young_driver_21_25: 'Young driver, 21 to 25', young_driver_18_20: 'Young driver, 18 to 20', additional_driver: 'Additional driver',
  coverage_sold: 'Protection Plan', delivery: 'Delivery', pickup: 'Pickup (we collect the car)' };
export function lineHelp(code: string): string {
  if (code === 'rental_charge') return 'The car\'s rate for the whole trip, before fees and HST. From the rate sheet: 1 to 6 days at the daily or weekend rate (never more than the weekly rate), 7 to 29 days at the weekly rate a day (never more than the monthly rate), 30 days or more at the monthly rate for each 30 days. Type a total for the trip, or choose "a day" and type the rate a day.';
  if (code.startsWith('young_driver')) return 'Charged for a driver under 26: a rate a day up to a cap per rental (per 30 days on a long rental), from Settings, fees. Type the amount for the whole trip to change it; 0 removes it.';
  if (code === 'additional_driver') return 'Each driver besides the renter: a rate a day up to a cap per rental, from Settings, fees. Type the amount for the whole trip.';
  if (code === 'coverage_sold') return 'Option 3, the Protection Plan: covers damage to the car instead of the renter\'s own insurance or a credit card\'s. Priced from Settings, Protection Plan prices (a day or per rental). Type the amount for the whole trip.';
  if (code === 'delivery' || code === 'pickup') return 'Bringing the car to the renter, or collecting it: from the car\'s rate card or the distance. Type the amount to change it.';
  if (['vlf', 'ldw', 'tldw', 'pap_pec', 'waiver_saver'].includes(code)) return 'A charge to the insurer on an insurance replacement (VLF, LDW, T&LDW, PAP/PEC or Waiver Saver): the rate a day typed for this booking, times the days, plus HST. Insurer bookings only.';
  if (code === 'custom_fee') return 'A charge the list has not got. The renter sees what you type. Tick HST when tax applies.';
  if (code === 'hst') return '13% Ontario HST on each taxable line, worked out from the amounts above.';
  if (code === 'deposit') return 'Taken at pickup (a card hold, cash or e-Transfer) and given back after the return, less any charges. Not part of the total.';
  if (code === 'km') return 'Kilometres included a day, times the days. Extra kilometres are charged at the return at the car\'s rate per km.';
  if (['winter_tire', 'baby_seat', 'addon'].includes(code)) return 'An add-on: priced from the add-on list (a day up to a cap, or per trip). Type the amount for the whole trip to change it; 0 removes it.';
  return 'A line of this booking\'s price. Type a new amount (before HST) to change it.';
}

