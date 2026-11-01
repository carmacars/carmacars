# The company statement ties an owner invoice paid on a car not yet enrolled (0281)

The company statement's cash tie said "not tied to a booking or an owner invoice" for a payment that was tied to an
owner invoice: the upfront invoice of a car signed but not yet enrolled, paid by the owner's bank debit in the month.
The statement built a vehicle line only for an enrolled car or a car with rentals, fees, Turo trips, expenses, tolls or a
booking payment in the month, so that payment had no vehicle line to land on and the month could not be finalized.

Now (migration 0281) a car with an owner invoice payment in the month has its vehicle line too, with the cash collected,
and the tie passes. Nothing else on the statement changes.

Company statements also open on last month in Toronto time: on the evening of a month's last day the page no longer
opens on the month still running.

## Guides

No guide change: the statement is built and read the same way; a paid upfront invoice now ties.
