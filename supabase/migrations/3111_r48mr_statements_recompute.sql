-- 3111 (release 48, part MR; docs/changes/2026-11-20-r48-money-rules.md): the owner statements approved and not paid out
-- (ST-1002 and the others of November 10) recomputed on the corrected terms and rules of 3100 and 3110: each is voided,
-- built again and approved again (app.owner_statement_recompute), with an audit line of the amounts before and after.
-- A statement whose amounts come out the same is left as it is. The referred owners' statements are recomputed before
-- the referrers' (a referral share is paid on the referrer's statement). Runs once and again without change: a
-- statement this migration already made is not recomputed again.
set local check_function_bodies = off;

do $$
declare
  v_by uuid;
  st owner_statements;
  n owner_statements;
  v_new uuid;
  v_reason constant text := 'Release 48: recomputed on the agreed terms (the term in force each rental day, shareholder 90% of everything charged, owner referral share)';
begin
  select x.approved_by into v_by from owner_statements x where x.approved_by is not null and app.user_is_admin(x.approved_by) order by x.approved_at desc limit 1;
  if v_by is null then raise notice '3111: no approved statement; nothing to do'; return; end if;
  for st in select s.* from owner_statements s
             where s.status = 'approved'
               and not exists (select 1 from payouts p where p.owner_statement_id = s.id and p.status in ('sent', 'paid'))
               and not exists (select 1 from audit_log l where l.action = 'owner_statement_recompute' and l.after ->> 'statement_id' = s.id::text and l.after ->> 'reason' = v_reason)
             order by (exists (select 1 from owner_referral_links l where l.referrer_owner_id = s.owner_id and l.effective_to is null)), s.statement_month, s.statement_number loop
    begin
      v_new := app.owner_statement_recompute(st.id, v_by, v_reason);
      select * into n from owner_statements where id = v_new;
      if (n.owner_revenue_cents, n.revenue_share_cents, n.kickbacks_earned_cents, n.payout_cents, n.balance_carried_forward_cents)
         is not distinct from (st.owner_revenue_cents, st.revenue_share_cents, st.kickbacks_earned_cents, st.payout_cents, st.balance_carried_forward_cents) then
        raise exception using errcode = 'P0001', message = 'cc3111:same';
      end if;
      raise notice '3111: % (payout %) is now % (payout %)', st.statement_number, st.payout_cents, n.statement_number, n.payout_cents;
    exception when sqlstate 'P0001' then
      if sqlerrm <> 'cc3111:same' then raise; end if;
    end;
  end loop;
end $$;
