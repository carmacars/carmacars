// The writing kit's phrase library for the vehicle pages (migration 0097): make, model, year, trim, and a trim in a
// place or a colour, and their twins under /buy and /t/<term>. Hand-written; the numbers come only from the page's
// sourced figures (EPA, Natural Resources Canada, NHTSA vPIC and recalls) and our own cars, said in plain words.
// A sentence that starts with #topic is skipped when another sentence on the page already said that.
import type { Bank } from '../engine.ts';

export const VEHICLES: Record<string, Bank> = {
  // ================================================================ make
  'vm.h.intro': ['{make} at a glance', 'About {make}', 'The {make} lineup', '{make} models in our catalog', 'Renting a {make}', '{make}: the short version', 'Every {make}, model by model', '{make} in numbers'],
  'vm.intro': [
    'This page brings together every {make} model in our catalog, from {firstYear} to {lastYear}.',
    'Our catalog lists {models} {make} models, each with its own years and trims.',
    '{make} has {models} models in our catalog, with figures from the EPA and NHTSA where they publish them.',
    'Here you will find {models} {make} models, from the {firstYear} model year to {lastYear}.',
    'Every {make} model we have figures for is listed here, {models} in all.',
    'The {make} pages below cover {models} models and their Canadian trims.',
    'Browse {make} by model, then by year and trim: {models} models so far.',
    'From {firstYear} to {lastYear}, our catalog has {models} {make} models.',
    'Looking at a {make}? Start with the model, then pick the year and the trim.',
    '{models} {make} models, each with its fuel use and Canadian trims: that is what this page lists.'
  ],
  'vm.models': [
    'Models include {modelList}.',
    'Among them: {modelList}.',
    'You will find the {modelList}, among others.',
    'The list includes {modelList}.',
    'Familiar names here include the {modelList}.'
  ],
  'vm.ev': [
    ['make-ev', '#ev {evModels} of them come as fully electric models.'],
    ['make-ev', '#ev The catalog includes {evModels} electric {make} models.'],
    ['make-hybrid', '#hy {hybridModels} {make} models offer a hybrid powertrain.'],
    ['make-hybrid', '#hy There are hybrids too: {hybridModels} models have one.']
  ],
  'vm.how': [
    'Each model page lists its years; each year lists its powertrains and Canadian trims.',
    'Open a model to see its years, then a year to see the trims sold in Canada.',
    'Every year page shows fuel use for each powertrain, from the EPA rating.',
    'Trim pages compare a trim with the others of the same year.',
    '#src Figures come from the US EPA and NHTSA, and we leave out any figure no free source publishes.',
    '#src We only show figures a public source publishes; power and torque are left out for that reason.',
    'Fuel use is shown in litres per 100 km, converted from the EPA rating.'
  ],

  // ================================================================ model, year, trim: the intro
  'v.h.intro': [
    'About the {car}', 'The {car} at a glance', 'The {car}, briefly', 'What to know about the {car}', 'Meet the {car}', 'The {car} in short',
    'The {car}: an overview', 'The {car} in plain words', 'Getting to know the {car}', 'The {car}, explained'
  ],
  'v.intro.model': [
    'The {makeModel} is {aBody}, with pages for each model year.',
    '{makeModel} pages cover {yearsCount} model years, from {firstYear} to {lastYear}.',
    'Our catalog has the {makeModel} from {firstYear} to {lastYear}, {yearsCount} model years in all.',
    'The {makeModel} appears in our catalog from {firstYear} on.',
    'Here is the {makeModel} across its years, with fuel use and trims for each one.',
    'This page covers every {makeModel} year we have figures for, from {firstYear} to {lastYear}.',
    'The {makeModel}, {aBody}, has {yearsCount} model years in our catalog.',
    'From {firstYear} to {lastYear}, the {makeModel} pages list each year\'s powertrains and trims.'
  ],
  'v.intro.best': [
    'Of those years, the {bestYear} has the lowest rated fuel use.',
    'The most efficient year in the catalog is the {bestYear}.',
    'If fuel use matters most, look at the {bestYear} first.',
    'The {bestYear} model year uses the least energy of the years listed.'
  ],
  'v.intro.trims': [
    ['trims', 'Canadian trims include {trimList}.'],
    ['trims', 'In Canada it is sold as the {trimList}.'],
    ['trims', 'The Canadian lineup includes {trimList}.'],
    ['trims', 'Trims sold in Canada: {trimList}.'],
    ['manytrims', 'There are {trimCount} Canadian trims to compare: {trimList}.']
  ],
  'v.intro.year': [
    'The {car} is {aBody}.',
    ['manypt', 'The {car} came with {powertrains} powertrains; the most efficient is the {engine}.'],
    ['onept', 'The {car} came with one powertrain, the {engine}.'],
    'Here is the {car}: its powertrains, its fuel use and the trims sold in Canada.',
    'This page sets out the {car} in numbers and in plain words.',
    'The {car} at a glance: {aBody}[ with the {engine}].',
    'If you are looking at the {car}, here is what the figures say.'
  ],
  'v.intro.trim': [
    '#what The {car} is {aBody}[ with the {engine}].',
    '#what This page is about one trim: the {car}.',
    '#what Here is the {car} in plain words: what it is, what it uses, and who it suits.',
    '#what The {car}, {aBody}, in numbers and in plain words.',
    ['onlytrim', '#rank The {trim} is the only trim listed for the {year} {makeModel} in Canada.'],
    ['entrytrim', '#rank The {trim} is the entry trim of the {year} {makeModel}, the first of {trimOf} in Canada.'],
    ['toptrim', '#rank The {trim} sits at the top of the {year} {makeModel} lineup, trim {trimRank} of {trimOf}.'],
    ['midtrim', '#rank The {trim} is trim {trimRank} of {trimOf} in the Canadian lineup of the {year} {makeModel}.'],
    ['midtrim', '#rank In the {year} lineup, the {trim} sits between the entry trim and the top one: number {trimRank} of {trimOf}.']
  ],

  // ================================================================ what it is like
  'v.h.like': ['What the {model} is like', 'Size and space', 'The {model} in everyday use', 'Living with the {model}', 'What to expect from the {model}', 'Space, size and seats', 'How big it is', 'Room inside'],
  'v.like.body': [
    ['suv', '#body As {aBody}, it sits higher than a sedan, which makes getting in and loading easier.'],
    ['suv', '#body An SUV body means more headroom and a taller cargo opening than a car of the same length.'],
    ['suv', '#body The higher seat of {aBody} gives a good view of the road in traffic.'],
    ['sedan', '#body As {aBody}, it is easy to drive and park in the city.'],
    ['sedan', '#body A car body like this keeps the weight low, so it feels settled on the highway.'],
    ['sedan', '#body As {aBody}, it has a closed trunk that keeps luggage out of sight.'],
    ['truck', '#body As {aBody}, it has an open bed for things that would never fit in a trunk.'],
    ['truck', '#body A pickup is long and tall, so plan for parking and low garages.'],
    ['van', '#body As {aBody}, it puts space for people and luggage first.'],
    ['van', '#body A tall roof and wide doors make it easy to load people and bags.'],
    ['sports', '#body As {aBody}, it puts the driving first and the luggage second.'],
    ['sports', '#body Low and compact, it is a car for the drive more than the cargo.'],
    ['wagon', '#body As {aBody}, it has the length of a car with a bigger load space at the back.']
  ],
  'v.like.size': [
    '#len It is {lengthM} m long. {lengthTip}',
    '#len Length: {lengthM} m. {lengthTip}',
    '#len NHTSA lists it at {lengthM} m long. {lengthTip}',
    '#len The body is {lengthM} m long[ and {widthM} m wide]. {lengthTip}',
    '#len At {lengthM} m from bumper to bumper, it is {lengthSize}. {lengthTip}'
  ],
  'v.like.cargo': [
    '#cargo The EPA measures its luggage space at {cargoL} litres, roughly {cargoPlain}.',
    '#cargo With {cargoL} litres of luggage space by the EPA\'s measure, it takes {cargoPlain}.',
    '#cargo Luggage space is {cargoL} litres, enough for {cargoPlain}.',
    '#cargo At {cargoL} litres, the trunk fits {cargoPlain}.',
    '#cargo In plain terms, its {cargoL} litres of luggage space hold {cargoPlain}.'
  ],
  'v.like.seats': [
    '#seats Our car of this model has {seats} seats.',
    '#seats The one in our fleet seats {seats}.',
    ['seats7', '#seats With {seats} seats, it takes a family or a small group in one car.'],
    '#seats It seats {seats}, going by our own car of this model.'
  ],
  'v.like.weight': [
    '#weight Its curb weight is {weightKg} kg, by NHTSA\'s Canadian specifications.',
    '#weight It weighs {weightKg} kg empty, according to NHTSA.'
  ],

  // ================================================================ the numbers in plain words
  'v.h.spec': ['The numbers in plain words', 'What the specs mean', 'Specs, explained', 'The figures, translated', 'What the figures tell you', 'Reading the spec sheet', 'Engine and fuel', 'Under the hood'],
  'v.spec.engine': [
    '#engine The engine is the {engine}[, with {drive}][ and {aTrans}].',
    '#engine Power comes from the {engine}[, driving through {aTrans}].',
    '#engine Under the hood: the {engine}[ and {drive}].',
    '#engine It runs the {engine}[, with {drive}].',
    '#engine The {engine}[ with {drive}] is the powertrain to look at.'
  ],
  'v.spec.drive': [
    ['awd', 'All-wheel drive sends power to all four wheels, which helps on snow and wet roads; good tires still matter most.'],
    ['awd', 'With all-wheel drive, it pulls away more surely on slippery roads, though it does not stop any shorter.'],
    ['awd', 'All-wheel drive helps when pulling away on snow; braking and steering still depend on the tires.'],
    ['4wd', 'Four-wheel drive helps on rough ground and deep snow; on dry roads it behaves like any other vehicle.'],
    ['fwd', 'Front-wheel drive is the usual layout for cars this size, predictable in the rain and the snow.'],
    ['fwd', 'With front-wheel drive, the weight of the engine sits over the driven wheels, which helps in winter.'],
    ['rwd', 'Rear-wheel drive gives balanced handling; in winter, the tires make the biggest difference.']
  ],
  'v.spec.trans': [
    ['cvt', 'The gearbox is a continuously variable automatic, so there are no gear changes to feel.'],
    ['auto', 'It shifts by itself; there is no clutch pedal to think about.'],
    ['manual', 'It has a manual gearbox, so you need to be comfortable with a clutch.']
  ],
  'v.spec.fuel': [
    ['ev', '#fuel It is fully electric: no gas at all, and you return it with the charge it had at pickup.'],
    ['ev', '#fuel Being electric, it is quiet and quick from a stop, and it charges at home, at work or at public chargers.'],
    ['phev', '#fuel It is a plug-in hybrid: it runs on electricity for a short distance, then on gas like a regular hybrid.'],
    ['hybrid', '#fuel It is a hybrid: the battery charges itself as you drive and brake, so there is nothing to plug in.'],
    ['hybrid', '#fuel As a hybrid, it does best in stop-and-go traffic, where the electric motor does more of the work.'],
    ['premium', '#fuel It calls for premium gas, which costs more a litre than regular.'],
    ['diesel', '#fuel It runs on diesel, sold at most highway stations.'],
    ['gas', '#fuel It runs on regular gas.'],
    ['gas|premium turbo', '#fuel The turbo gives a small engine the pull of a bigger one when you need it.']
  ],
  'v.spec.use': [
    '#use The EPA rates it at {l100} L/100 km combined, so a 300 km weekend uses about {litres300} litres.',
    '#use At {l100} L/100 km combined, a 300 km drive takes roughly {litres300} litres of fuel.',
    '#use Combined fuel use is {l100} L/100 km: about {litres300} litres for 300 km.',
    '#use Rated at {l100} L/100 km combined, it needs around {litres300} litres for a 300 km round trip.',
    '#use Expect about {litres300} litres for every 300 km, going by its {l100} L/100 km combined rating.',
    ['thrifty', '#use At {l100} L/100 km combined, it is easy on fuel: about {litres300} litres for 300 km.'],
    ['thirsty', '#use It is rated at {l100} L/100 km combined, so budget about {litres300} litres for 300 km.']
  ],
  'v.spec.cityhwy': [
    'In the city it is rated at {l100City} L/100 km, and on the highway {l100Hwy}.',
    'City driving is rated {l100City} L/100 km and highway driving {l100Hwy}.',
    'The split is {l100City} L/100 km in town and {l100Hwy} on the highway.'
  ],
  'v.spec.kwh': [
    '#use It uses {kwh100} kWh per 100 km, so 300 km takes about {kwh300} kWh of charge.',
    '#use At {kwh100} kWh/100 km, a 300 km day uses roughly {kwh300} kWh.',
    '#use Energy use is rated at {kwh100} kWh/100 km, about {kwh300} kWh for 300 km.'
  ],
  'v.spec.range': [
    ['range', '#range Its rated range is {range} km on a full charge; real range drops in cold weather and at highway speeds.'],
    ['range', '#range The EPA rates its range at {range} km. Winter cold and fast highway driving cut that down.'],
    ['range', '#range On paper it goes {range} km between charges, less in winter.'],
    ['phevrange', '#range On electricity alone it is rated for about {range} km before the gas engine takes over.']
  ],
  'v.spec.cost': [
    '#cost At our price setting, driving 100 km costs about {cost100}, and a 300 km weekend about {cost300}.',
    '#cost That works out to about {cost100} per 100 km at our price setting.',
    '#cost In money, 1,000 km costs about {cost1000} at our price setting.',
    '#cost A 300 km weekend costs about {cost300} in energy at our price setting.',
    '#cost Per 100 km, plan on roughly {cost100}.'
  ],
  'v.spec.premium': [
    ['premium', 'We count premium at {premiumPrice} for the cost figures on this page.']
  ],
  'v.spec.mpg': [
    'In US terms that is {mpg} MPG combined.',
    'For those who think in miles, it is rated {mpg} MPG (US) combined.'
  ],
  'v.spec.co2': [
    'The EPA lists its CO2 at {co2} g/km.',
    'Tailpipe CO2 is rated at {co2} g/km.'
  ],
  'v.spec.charge': [
    ['charge', 'On a 240 V charger it fills in about {charge240} hours, by the EPA\'s figure.'],
    ['charge', 'A full charge at 240 V takes about {charge240} hours.']
  ],
  'v.spec.year': [
    'EPA puts its fuel cost at {fuelYearUsd} a year for 15,000 miles at US prices.',
    'The EPA estimates {fuelYearUsd} a year in fuel for 15,000 miles.'
  ],
  'v.spec.nospecs': [
    ['nospecs', 'The EPA does not rate this model year for fuel use; heavier trucks and vans are often not rated.'],
    ['nospecs', 'No fuel-use rating is published for this model year, so we leave those figures out.']
  ],

  // ================================================================ who it suits
  'v.h.who': ['Who the {model} suits', 'Who it is for', 'Good uses for the {model}', 'When the {model} makes sense', 'Is it right for your trip?', 'Who rents the {model}', 'Best uses', 'A good match for'],
  'v.who': [
    ['suv', 'Families, skiers and anyone with bulky luggage.'],
    ['suv', 'It suits winter trips and weekends with more gear than people.'],
    ['suv seats7', 'It suits families who need every seat and some luggage room too.'],
    ['sedan', 'It suits commuters, couples and business trips.'],
    ['sedan thrifty', 'Its low fuel use suits long commutes and high-kilometre weeks.'],
    ['sedan short', 'Its size suits city driving and street parking.'],
    ['truck', 'It suits moving day, renovation runs and anything that needs an open bed.'],
    ['van', 'It suits groups, airport runs with luggage and family trips.'],
    ['sports', 'It suits a summer weekend or a special occasion more than a move.'],
    ['wagon', 'It suits people who want car handling with extra load space.'],
    ['ev', 'It suits city driving and anyone with charging at home or work.'],
    ['ev', 'It suits people who want to try an electric car before buying one.'],
    ['hybrid', 'It suits stop-and-go driving and rideshare or delivery work.'],
    ['phev', 'It suits short daily drives on electricity with gas for longer trips.'],
    ['luxury', 'It suits client visits, weddings and special weekends.'],
    ['awd', 'Its all-wheel drive suits winter roads and trips to ski country.'],
    ['thirsty', 'It uses more fuel than most, so it suits shorter trips or people who need its size.'],
    'It suits anyone who needs a car for a few days, a week or a month without buying one.',
    'It suits people curious about the model who want to drive it before they buy.',
    'It suits someone whose own car is in the shop for a while.'
  ],

  // ================================================================ trips
  'v.h.trip': ['Trips in the {model}', 'Taking it further', 'Road trips', 'How far it goes', 'Out of town', 'Longer drives'],
  'v.trip': [
    ['rangetrip', 'Its rated range covers a drive like Toronto to {rangeTrip}, about {rangeTripKm} km, with a margin.'],
    ['rangetrip', 'On paper, {rangeTrip} (about {rangeTripKm} km from Toronto) is reachable on one charge.'],
    ['cost', '#cost A weekend of about 300 km costs roughly {cost300} in energy at our price setting.'],
    ['burns l100', '#use A 300 km weekend uses around {litres300} litres.'],
    'Each car shows the kilometres included each day and the rate for extra ones.',
    '#ont Trips outside Ontario need our written consent, agreed before you go.',
    '#return Return the car with the same {level} it had at pickup.'
  ],

  // ================================================================ renting it from CarmaCars
  'v.h.rent': ['Renting the {model} from CarmaCars', 'Can you rent one?', 'Renting this car', 'Our {model} cars', 'Getting one from us', 'Rent it from us', 'In our fleet'],
  'v.rent': [
    ['cars !level-make', '#count We have {cars} on the site now, each with its own calendar and price.'],
    ['cars level-make', '#count We have {cars} {make} cars on the site now, each with its own calendar and price.'],
    ['cars', '#count Our fleet has {cars} matching this page; choose your dates on the car\'s page.'],
    ['cars', '#count {cars} of our cars match this page. Each one shows its rates and its calendar.'],
    ['cars price', '#price Our matching cars start at {fromDaily} a day before tax.'],
    ['cars price', '#price Rates for our matching cars start at {fromDaily} a day.'],
    ['nocars !level-make', '#none We have none on the site right now. Send a request for this exact car and we look for one for your dates.'],
    ['nocars level-make', '#none We have no {make} on the site right now. Send a request with the model you want, and we look for one for your dates.'],
    ['nocars level-make', '#none No {make} is in our fleet today; ask for one in a request and we search for your dates.'],
    ['nocars !level-make', '#none There is no exact match in our fleet today. Request it and we search for one, or take a similar car.'],
    ['nocars !level-make', '#none This exact car is not in our fleet at the moment; a request asks us to look for one.'],
    ['nocars similar', '#similar Meanwhile, {similar} similar cars are listed below.'],
    ['nocars similar', '#similar Similar cars are below if you need one sooner.'],
    ['!level-make', '#ask Ask for this exact car in your request, and we tell you what we can offer.'],
    '#ask Want a car for specific dates? Put them in the request and we check.'
  ],
  'v.del': [
    ['!far', '#del We deliver across the Toronto area, or you collect the car from our location for free.'],
    ['!far', '#del Delivery covers the Toronto area, priced by distance in your offer; pickup from us is free.'],
    ['!far', '#del The car can come to your door in the Toronto area, or you pick it up at no charge.'],
    ['!far', '#del Delivery starts at {{delMin}} plus distance; collecting the car yourself is free.'],
    ['!far', '#del We hand every car over in person, at your address or at our location.']
  ],

  // ================================================================ place and colour pages
  'vc.h.city': ['The {model} and {place}', '{place} and the {model}', ['served', 'Getting the {model} in {place}'], ['served', 'Delivery to {place}'], ['served', 'The {model} near {place}'], ['far', 'Renting for {place}'], ['far', 'A note on {place}'], ['wide', 'The {model} across {place}']],
  'vc.city': [
    ['served', '#km We deliver the {model} to {place}, about {km} km from our location in a straight line.'],
    ['served', '#km {place} is about {km} km from our location, inside our delivery area.'],
    ['served', '#km At about {km} km from our location, {place} is well within our delivery area.'],
    ['served fee', '#fee Delivery to {place} starts at {deliveryFrom}, priced in your offer.'],
    ['served fee', '#fee Bringing the car to {place} starts at {deliveryFrom}.'],
    ['served', '#pick Collecting the car yourself at our location is free.'],
    ['served', '#pick You can also pick it up from us in Toronto at no charge.'],
    ['far', '#far CarmaCars is based in Toronto, about {km} km from {place}, and does not deliver there.'],
    ['far', '#far {place} is about {km} km from our Toronto location, beyond the area we deliver to.'],
    ['far', '#farask We rent from Toronto only. If your trip to {place} starts in the Toronto area, rent the car here.'],
    ['far', '#farask If you need it in {place} itself, send a request and we will tell you honestly whether we can help.'],
    ['wide', '#wide This page covers {place} as a whole; each town in it has its own page with its distance from us.']
  ],
  'vc.h.colour': ['The {model} in {colour}', 'About the colour', 'In {colour}', 'Choosing a colour', 'Colour notes'],
  'vc.colour': [
    'Our {colour} cars of this kind are listed first, when we have one.',
    'A colour can never be promised before we confirm; ask for {colour} in your request.',
    'If you want it in {colour}, say so in your request and we look for one for your dates.',
    'The studio image shows the {model} in {colour}; photos of each real car are on its page.',
    'Tell us if {colour} is a must or a preference, and we look accordingly.',
    'Colour is confirmed in your offer, never before.'
  ]
};
