-- MJ Tees: all new payment entries are manual Cash or M-Pesa Paybill only.
-- Legacy bank and cheque records remain stored and readable for historical reporting.
begin;

create or replace function private.guard_sales_new_payment_method()
returns trigger
language plpgsql
set search_path=''
as $function$
begin
  if new.method not in ('cash','mpesa_manual') then
    raise exception using
      errcode='22023',
      message='New payments must be recorded as Cash or M-Pesa Paybill';
  end if;
  return new;
end;
$function$;

create trigger payments_sales_new_method_guard
  before insert on public.payments
  for each row execute function private.guard_sales_new_payment_method();

create or replace function private.guard_sales_new_payment_account_type()
returns trigger
language plpgsql
set search_path=''
as $function$
begin
  if tg_op='INSERT' and new.account_type not in ('cash','mpesa_paybill') then
    raise exception using
      errcode='22023',
      message='New receiving accounts must be Cash or M-Pesa Paybill';
  end if;

  if tg_op='UPDATE'
     and new.account_type not in ('cash','mpesa_paybill')
     and new.account_type is distinct from old.account_type then
    raise exception using
      errcode='22023',
      message='New receiving accounts must be Cash or M-Pesa Paybill';
  end if;

  return new;
end;
$function$;

create trigger sales_payment_accounts_new_method_guard
  before insert or update of account_type on public.sales_payment_accounts
  for each row execute function private.guard_sales_new_payment_account_type();

revoke all on function private.guard_sales_new_payment_method() from public,anon,authenticated;
revoke all on function private.guard_sales_new_payment_account_type() from public,anon,authenticated;

commit;
