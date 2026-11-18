-- Prevent transactions being backdated into already-confirmed financial periods.

create or replace function private.guard_closed_cash_day()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_date date; v_business uuid; v_is_cash boolean:=false;
begin
  if tg_table_name='payments' then
    v_date:=(new.received_at at time zone 'Africa/Nairobi')::date;
    v_business:=new.business_id;
    v_is_cash:=new.method='cash';
    if new.method='mpesa_manual' and exists(
      select 1 from public.daily_payment_reconciliations r
      where r.business_id=v_business and r.business_date=v_date and r.method='mpesa' and r.status='confirmed'
    ) then
      raise exception using errcode='55000',message='This M-Pesa statement date is confirmed; do not add backdated evidence';
    end if;
  elsif tg_table_name='expenses' then
    v_date:=new.expense_date;
    v_business:=new.business_id;
    v_is_cash:=new.payment_method='cash';
  end if;
  if v_is_cash and exists(select 1 from public.daily_closings where business_id=v_business and business_date=v_date and status='closed') then
    raise exception using errcode='55000',message='This cash day is already closed; use an audited current-day correction';
  end if;
  return new;
end;
$$;

create or replace function private.guard_posted_refund_period()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_date date;
begin
  if new.status='posted' then
    v_date:=(coalesce(new.posted_at,now()) at time zone 'Africa/Nairobi')::date;
    if new.refund_method='cash' and exists(
      select 1 from public.daily_closings c where c.business_id=new.business_id and c.business_date=v_date and c.status='closed'
    ) then
      raise exception using errcode='55000',message='Cash closing is confirmed for this date; post the refund in the current cash period';
    end if;
    if new.refund_method='mpesa' and exists(
      select 1 from public.daily_payment_reconciliations r where r.business_id=new.business_id and r.business_date=v_date and r.method='mpesa' and r.status='confirmed'
    ) then
      raise exception using errcode='55000',message='M-Pesa reconciliation is confirmed for this date; post the refund in the current reconciliation period';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists payment_refunds_guard_confirmed_period on public.payment_refunds;
create trigger payment_refunds_guard_confirmed_period before insert or update on public.payment_refunds
for each row execute function private.guard_posted_refund_period();

create or replace function private.guard_confirmed_financial_snapshot_inputs()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if tg_table_name='daily_closings' and new.status='closed' then
    if exists(select 1 from public.payment_refunds f
      where f.business_id=new.business_id and f.refund_method='cash' and f.status='pending'
        and (f.created_at at time zone 'Africa/Nairobi')::date=new.business_date) then
      raise exception using errcode='55000',message='Resolve pending cash refunds for this date before closing the till';
    end if;
  elsif tg_table_name='daily_payment_reconciliations' and new.status='confirmed' then
    if exists(select 1 from public.payment_refunds f
      where f.business_id=new.business_id and f.refund_method='mpesa' and f.status='pending'
        and (f.created_at at time zone 'Africa/Nairobi')::date=new.business_date) then
      raise exception using errcode='55000',message='Resolve pending M-Pesa refunds for this date before confirming reconciliation';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists daily_closings_guard_pending_cash_refunds on public.daily_closings;
create trigger daily_closings_guard_pending_cash_refunds before insert or update on public.daily_closings
for each row execute function private.guard_confirmed_financial_snapshot_inputs();
drop trigger if exists daily_payment_reconciliations_guard_pending_refunds on public.daily_payment_reconciliations;
create trigger daily_payment_reconciliations_guard_pending_refunds before insert or update on public.daily_payment_reconciliations
for each row execute function private.guard_confirmed_financial_snapshot_inputs();
