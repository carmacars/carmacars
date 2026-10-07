-- 0010_investors.sql
-- Investors and investment contracts: the register, Schedule A tranches, the six-month lockup,
-- monthly Returns (paid on the 15th or reinvested), elections, redemptions on six months'
-- notice, purchases on request and transfers. Source: docs/source/v2_investment.md.
-- Admin only, apart from an investor reading their own records.

create table investors (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid unique references users (id),
  legal_name         text not null,
  investor_type      text not null check (investor_type in ('individual', 'corporation', 'trust', 'other')),
  address            text,
  email              text,
  phone              text,
  tax_resident_canada boolean not null default true,
  tax_country        text,
  tax_information_complete boolean not null default false,  -- payment may be held back until it is (3.4)
  identification_verified_at timestamptz,
  status             text not null default 'prospect' check (status in ('prospect', 'active', 'exited', 'refused')),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (tax_resident_canada or tax_country is not null)
);
create trigger investors_updated before update on investors for each row execute function app.set_updated_at();

-- Bank account for payments (Schedule A). Admin and the investor only.
create table investor_bank_accounts (
  id             uuid primary key default gen_random_uuid(),
  investor_id    uuid not null references investors (id) on delete cascade,
  account_holder text not null,                  -- an account in the Investor's name
  institution_no text,
  transit_no     text,
  account_no     text,                           -- application-layer encrypted
  account_last4  text,
  notified_on    date not null default app.today(),   -- a change applies 10 days after notice
  is_current     boolean not null default true,
  created_at     timestamptz not null default now()
);
create unique index investor_bank_accounts_current on investor_bank_accounts (investor_id) where is_current;

create table investment_agreements (
  id                 uuid primary key default gen_random_uuid(),
  investor_id        uuid not null references investors (id),
  agreement_number   text not null unique,
  status             text not null default 'draft' check (status in ('draft', 'sent', 'signed', 'ended', 'void')),
  document_id        uuid references documents (id),
  signature_request_id uuid references signature_requests (id),
  schedule_c_document_id uuid references documents (id),   -- risk acknowledgment, each statement initialled
  schedule_d_document_id uuid references documents (id),   -- exemption certificate
  legal_advice_choice text check (legal_advice_choice in ('obtained', 'declined')),
  legal_adviser      text,
  exemption_category text check (exemption_category in ('accredited_investor', 'offering_memorandum_eligible')),
  exemption_paragraph text,
  exemption_verification text,                     -- Company use only: steps taken to verify
  exempt_distribution_report_filed_on date,
  offering_memorandum_delivered_at timestamptz,
  company_signed_at  timestamptz,                  -- the Company is bound only when it has cleared funds and has signed
  reinvestment_suspended_from date,                -- 4.3
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  -- no funds are accepted before Schedules C and D are delivered
  check (status <> 'signed' or (schedule_c_document_id is not null and schedule_d_document_id is not null
                                and exemption_category is not null and legal_advice_choice is not null))
);
create unique index investment_agreements_one_live on investment_agreements (investor_id) where status in ('draft', 'sent', 'signed');
create trigger investment_agreements_updated before update on investment_agreements for each row execute function app.set_updated_at();

-- One row per amount invested (the initial investment and each additional one). Each has its
-- own Investment Date and Lockup Period.
create table investments (
  id                  uuid primary key default gen_random_uuid(),
  investor_id         uuid not null references investors (id),
  agreement_id        uuid not null references investment_agreements (id),
  is_initial          boolean not null default false,
  schedule_a_document_id uuid references documents (id),
  principal_cents     bigint not null check (principal_cents > 0),     -- the amount paid in
  yearly_bps          integer not null check (yearly_bps > 0),         -- the Yearly Percentage
  investment_date     date not null,                                   -- cleared funds received
  lockup_end_date     date not null,                                   -- six months after the Investment Date
  reinvested_cents    bigint not null default 0 check (reinvested_cents >= 0),
  redeemed_cents      bigint not null default 0 check (redeemed_cents >= 0),
  invested_amount_cents bigint generated always as (principal_cents + reinvested_cents - redeemed_cents) stored,
  status              text not null default 'active' check (status in ('active', 'redeemed', 'transferred')),
  transferred_from_investment_id uuid references investments (id),     -- keeps the same percentage and dates
  created_by          uuid references users (id),
  created_at          timestamptz not null default now(),
  check (redeemed_cents <= principal_cents + reinvested_cents),
  check (lockup_end_date = (investment_date + interval '6 months')::date or transferred_from_investment_id is not null)
);
create index investments_investor_idx on investments (investor_id);
create unique index investments_one_initial on investments (agreement_id) where is_initial;

create or replace function app.guard_investment() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_set program_settings := app.settings(new.investment_date);
begin
  if new.is_initial and new.transferred_from_investment_id is null and new.principal_cents < v_set.investor_min_cents then
    raise exception 'The minimum initial investment is $%', (v_set.investor_min_cents / 100) using errcode = '23514';
  end if;
  if not exists (select 1 from investment_agreements a where a.id = new.agreement_id and a.status = 'signed'
                   and a.investor_id = new.investor_id) then
    raise exception 'No funds are accepted before the Investment Agreement and Schedules C and D are signed' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger investments_guard before insert on investments for each row execute function app.guard_investment();

-- Pay monthly or reinvest. A change applies from the first Return Month that starts at least
-- 10 days after the Company receives it.
create table investment_elections (
  id             uuid primary key default gen_random_uuid(),
  agreement_id   uuid not null references investment_agreements (id),
  mode           text not null check (mode in ('pay', 'reinvest')),
  received_on    date not null,
  is_initial     boolean not null default false,       -- the choice in Schedule A applies from the start
  effective_month date not null check (extract(day from effective_month) = 1),
  notice_document_id uuid references documents (id),
  created_at     timestamptz not null default now(),
  unique (agreement_id, effective_month)
);

create or replace function public.calc_election_effective_month(p_received_on date, p_notice_days integer default 10)
returns date language sql immutable as $$
  select case when extract(day from (p_received_on + p_notice_days)) = 1
              then (p_received_on + p_notice_days)
              else (date_trunc('month', (p_received_on + p_notice_days)::timestamp) + interval '1 month')::date end
$$;

create or replace function app.investment_election_default() returns trigger
language plpgsql as $$
begin
  if new.effective_month is null then
    new.effective_month := case when new.is_initial then date_trunc('month', new.received_on)::date
                                else public.calc_election_effective_month(new.received_on) end;
  end if;
  return new;
end $$;
create trigger investment_elections_default before insert on investment_elections
  for each row execute function app.investment_election_default();

create or replace function app.investment_mode(p_agreement uuid, p_month date) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(
    (select case when a.reinvestment_suspended_from is not null and a.reinvestment_suspended_from <= app.month_start(p_month)
                 then 'pay' else e.mode end
       from investment_elections e join investment_agreements a on a.id = e.agreement_id
      where e.agreement_id = p_agreement and e.effective_month <= app.month_start(p_month)
      order by e.effective_month desc limit 1),
    'pay')
$$;

-- One Return per investment per Return Month.
create table investment_returns (
  id                uuid primary key default gen_random_uuid(),
  investment_id     uuid not null references investments (id),
  return_month      date not null check (extract(day from return_month) = 1),
  opening_invested_cents bigint not null,          -- the Invested Amount at the start of the month
  yearly_bps        integer not null,
  days_earning      integer not null check (days_earning >= 0),
  days_in_month     integer not null,
  return_cents      bigint not null check (return_cents >= 0),
  disposition       text not null check (disposition in ('pay', 'reinvest')),
  payment_date      date not null,                 -- the 15th of the month after the Return Month
  status            text not null default 'accrued' check (status in ('accrued', 'reinvested', 'paid', 'held', 'included_in_redemption')),
  hold_reason       text,                          -- tax information outstanding, or tax withheld
  withheld_tax_cents bigint not null default 0,
  payout_id         uuid references payouts (id),
  closing_invested_cents bigint not null,
  statement_document_id uuid references documents (id),
  statement_sent_at timestamptz,
  created_at        timestamptz not null default now(),
  unique (investment_id, return_month),
  check (days_earning <= days_in_month)
);
create index investment_returns_month_idx on investment_returns (return_month);

create table investment_redemptions (
  id                uuid primary key default gen_random_uuid(),
  investment_id     uuid not null references investments (id),
  kind              text not null check (kind in ('company_redemption', 'purchase_on_request', 'winding_up')),
  notice_date       date not null,                 -- company_redemption: the written notice; purchase: the request
  redemption_date   date not null,
  shorter_notice_document_id uuid references documents (id),  -- shorter notice agreed in writing
  agreement_document_id uuid references documents (id),       -- purchase on request: price and date agreed in writing
  amount_cents      bigint not null check (amount_cents > 0), -- the Invested Amount being redeemed
  unpaid_return_cents bigint not null default 0,
  price_cents       bigint,                        -- redemption: amount + unpaid Return; purchase: as agreed
  status            text not null default 'noticed' check (status in ('requested', 'refused', 'noticed', 'paid', 'cancelled')),
  payout_id         uuid references payouts (id),
  receipt_document_id uuid references documents (id),
  decided_by        uuid references users (id),
  created_at        timestamptz not null default now(),
  -- at least six months' written notice, or shorter notice agreed in writing
  check (kind <> 'company_redemption' or shorter_notice_document_id is not null
         or redemption_date >= (notice_date + interval '6 months')::date),
  check (redemption_date >= notice_date)
);
create index investment_redemptions_investment_idx on investment_redemptions (investment_id);

create or replace function app.guard_investment_redemption() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  i investments;
begin
  select * into i from investments where id = new.investment_id;
  -- only after the Lockup Period may the Investor ask the Company to buy
  if new.kind = 'purchase_on_request' and new.notice_date < i.lockup_end_date then
    raise exception 'A purchase can be requested only after the Lockup Period' using errcode = '23514';
  end if;
  if new.amount_cents > i.invested_amount_cents and new.status <> 'paid' then
    raise exception 'Cannot redeem more than the Invested Amount' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger investment_redemptions_guard before insert on investment_redemptions
  for each row execute function app.guard_investment_redemption();

create table investment_transfers (
  id                 uuid primary key default gen_random_uuid(),
  from_investment_id uuid not null references investments (id),
  to_investor_id     uuid not null references investors (id),
  to_investment_id   uuid references investments (id),
  amount_cents       bigint not null check (amount_cents > 0),
  reason             text not null default 'sale' check (reason in ('sale', 'assignment', 'death', 'incapacity')),
  effective_date     date,                          -- from the Company's written consent
  consent_document_id uuid references documents (id),
  status             text not null default 'requested' check (status in ('requested', 'consented', 'refused', 'completed')),
  decided_by         uuid references users (id),
  created_at         timestamptz not null default now(),
  -- void unless the Company consents in writing (death or incapacity needs evidence, not consent)
  check (status not in ('consented', 'completed') or consent_document_id is not null or reason in ('death', 'incapacity'))
);

alter table payouts add constraint payouts_investor_fk foreign key (investor_id) references investors (id);
alter table documents add column investor_id uuid references investors (id);

-- Accrue one Return Month for one investment (sections 3 and 4). Months are accrued in order.
create or replace function app.accrue_investment_return(p_investment uuid, p_month date)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  i investments;
  v_month date := app.month_start(p_month);
  v_month_end date := (app.month_start(p_month) + interval '1 month - 1 day')::date;
  v_dim integer := app.days_in_month(p_month);
  v_first date;
  v_last date;
  v_days integer;
  v_ret bigint;
  v_mode text;
  v_pay date;
  v_id uuid;
  v_payout uuid;
  v_inv investors;
begin
  select * into i from investments where id = p_investment for update;
  if i.status <> 'active' then return null; end if;
  -- no return is earned for the Lockup Period
  if v_month_end < i.lockup_end_date then return null; end if;
  if exists (select 1 from investment_returns where investment_id = p_investment and return_month = v_month) then
    return null;
  end if;
  if v_month > app.month_start(i.lockup_end_date) and not exists (
       select 1 from investment_returns where investment_id = p_investment
          and return_month = (v_month - interval '1 month')::date) then
    raise exception 'Accrue % first: Return Months are accrued in order', to_char(v_month - interval '1 month', 'YYYY-MM') using errcode = '23514';
  end if;

  v_first := greatest(v_month, i.lockup_end_date);
  -- the Return runs to the day before the Redemption Date
  select least(v_month_end, min(r.redemption_date) - 1) into v_last
    from investment_redemptions r
   where r.investment_id = p_investment and r.status in ('noticed', 'paid') and r.amount_cents >= i.invested_amount_cents;
  v_last := coalesce(v_last, v_month_end);
  v_days := greatest(0, v_last - v_first + 1);
  v_ret := public.calc_investment_return(i.invested_amount_cents, i.yearly_bps, v_days, v_dim);
  v_mode := app.investment_mode(i.agreement_id, v_month);
  v_pay := (v_month + interval '1 month')::date + ((app.settings(v_month)).investor_payment_day - 1);
  select * into v_inv from investors where id = i.investor_id;

  insert into investment_returns (investment_id, return_month, opening_invested_cents, yearly_bps, days_earning, days_in_month,
      return_cents, disposition, payment_date, status, hold_reason, closing_invested_cents)
  values (p_investment, v_month, i.invested_amount_cents, i.yearly_bps, v_days, v_dim, v_ret, v_mode, v_pay,
      case when v_mode = 'reinvest' then 'reinvested'
           when not v_inv.tax_information_complete then 'held' else 'accrued' end,
      case when v_mode = 'pay' and not v_inv.tax_information_complete then 'tax information outstanding' end,
      i.invested_amount_cents + case when v_mode = 'reinvest' then v_ret else 0 end)
  returning id into v_id;

  if v_mode = 'reinvest' then
    -- added to the Invested Amount on the last day of its Return Month; no new Lockup Period
    update investments set reinvested_cents = reinvested_cents + v_ret where id = p_investment;
  elsif v_ret > 0 and v_inv.tax_information_complete then
    insert into payouts (payee_type, investor_id, kind, amount_cents, scheduled_for, status)
    values ('investor', i.investor_id, 'investor_return', v_ret, v_pay, 'pending_approval')
    returning id into v_payout;
    update investment_returns set payout_id = v_payout where id = v_id;
  end if;
  return v_id;
end $$;

create or replace function app.accrue_investment_returns(p_month date) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
begin
  for r in select id from investments where status = 'active' order by investment_date, id loop
    if app.accrue_investment_return(r.id, p_month) is not null then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- When a Return's payout is paid, the Return is paid.
create or replace function app.investor_payout_paid() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.status = 'paid' and old.status <> 'paid' and new.payee_type = 'investor' then
    update investment_returns set status = 'paid' where payout_id = new.id and status in ('accrued', 'held');
    update investment_redemptions r set status = 'paid' where r.payout_id = new.id and r.status = 'noticed';
    update investments i set redeemed_cents = i.redeemed_cents + r.amount_cents,
           status = case when i.invested_amount_cents - r.amount_cents <= 0 then 'redeemed' else i.status end
      from investment_redemptions r where r.payout_id = new.id and r.investment_id = i.id;
  end if;
  return null;
end $$;
create trigger payouts_investor_paid after update of status on payouts
  for each row execute function app.investor_payout_paid();
