-- MJ Tees Sales — manually recorded payments and account reconciliation.
-- Cash, M-Pesa Paybill, bank transfer and cheque are entered by the owner.
-- No gateway, callbacks, webhooks, automatic imports or automatic matching.
-- Apply only after the earlier bulk-printing and Sales foundation migrations.

begin;

create table public.sales_payment_accounts (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete restrict,
  account_name text not null check (length(btrim(account_name)) between 1 and 100),
  account_type text not null check (account_type in ('cash','mpesa_paybill','bank','cheque_clearing')),
  account_reference text,
  bank_name text,
  is_active boolean not null default true,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sales_payment_accounts_business_id_id_key unique (business_id,id),
  constraint sales_payment_accounts_name_key unique (business_id,account_name),
  constraint sales_payment_accounts_reference_length check (
    account_reference is null or length(account_reference)<=160
  ),
  constraint sales_payment_accounts_bank_name_length check (
    bank_name is null or length(bank_name)<=120
  ),
  constraint sales_payment_accounts_shape check (
    (account_type='bank' and nullif(btrim(bank_name),'') is not null)
    or account_type<>'bank'
  )
);

create index sales_payment_accounts_active_idx
  on public.sales_payment_accounts(business_id,is_active,account_type);

alter table public.payments
  add column duplicate_reference_warning boolean not null default false,
  add column receiving_account_id uuid,
  add constraint payments_sales_receiving_account_fk
    foreign key (business_id,receiving_account_id)
    references public.sales_payment_accounts(business_id,id) on delete restrict;

-- Duplicate references must be visible to the owner as a warning, not silently
-- treated as proof of payment or rejected by a uniqueness constraint.
drop index if exists public.payments_mpesa_reference_uq;
create index payments_mpesa_reference_lookup_idx
  on public.payments(business_id,method,mpesa_reference_normalized)
  where method='mpesa_manual' and mpesa_reference_normalized is not null;
create index payments_external_reference_lookup_idx
  on public.payments(business_id,method,receiving_account_id,lower(btrim(external_reference)))
  where external_reference is not null;
create index payments_duplicate_reference_warning_idx
  on public.payments(business_id,received_at desc)
  where duplicate_reference_warning;

-- A row means the owner manually checked this payment against the receiving
-- account's statement, Paybill statement or physical cash record.
create table public.sales_payment_reconciliations (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  payment_id uuid not null,
  receiving_account_id uuid not null,
  reconciliation_date date not null,
  statement_reference text,
  notes text,
  reconciled_by uuid not null references auth.users(id) on delete restrict,
  request_id uuid not null,
  reconciled_at timestamptz not null default now(),
  constraint sales_payment_reconciliations_payment_fk
    foreign key (business_id,payment_id) references public.payments(business_id,id) on delete restrict,
  constraint sales_payment_reconciliations_account_fk
    foreign key (business_id,receiving_account_id) references public.sales_payment_accounts(business_id,id) on delete restrict,
  constraint sales_payment_reconciliations_one_per_payment unique (business_id,payment_id),
  constraint sales_payment_reconciliations_request_unique unique (business_id,request_id),
  constraint sales_payment_reconciliations_reference_length
    check (statement_reference is null or length(statement_reference)<=160),
  constraint sales_payment_reconciliations_notes_length
    check (notes is null or length(notes)<=1000)
);

create index sales_payment_reconciliations_account_date_idx
  on public.sales_payment_reconciliations(business_id,receiving_account_id,reconciliation_date desc);

create or replace function private.prevent_sales_payment_reconciliation_mutation()
returns trigger
language plpgsql
set search_path=''
as $function$
begin
  raise exception using errcode='55000',message='Payment reconciliation records are append-only';
end;
$function$;

create trigger sales_payment_reconciliations_append_only
  before update or delete on public.sales_payment_reconciliations
  for each row execute function private.prevent_sales_payment_reconciliation_mutation();

alter table public.sales_payment_accounts enable row level security;
alter table public.sales_payment_reconciliations enable row level security;

create policy sales_payment_accounts_owner_read
  on public.sales_payment_accounts for select to authenticated
  using (private.is_active_owner(business_id));
create policy sales_payment_reconciliations_owner_read
  on public.sales_payment_reconciliations for select to authenticated
  using (private.is_active_owner(business_id));

revoke all on table public.sales_payment_accounts from public,anon,authenticated;
revoke all on table public.sales_payment_reconciliations from public,anon,authenticated;
grant select on table public.sales_payment_accounts to authenticated;
grant select on table public.sales_payment_reconciliations to authenticated;

-- A request may allocate one payment to several invoices. Idempotency is
-- scoped to the request and invoice, rather than incorrectly limiting a request
-- to a single invoice allocation.
alter table public.sales_invoice_payment_allocations
  drop constraint sales_invoice_payment_allocations_request_unique;
alter table public.sales_invoice_payment_allocations
  add constraint sales_invoice_payment_allocations_request_invoice_unique
  unique (business_id,request_id,invoice_id);

create or replace function private.owner_upsert_sales_payment_account(
  p_business_id uuid,
  p_account_id uuid,
  p_account_name text,
  p_account_type text,
  p_account_reference text,
  p_bank_name text,
  p_is_active boolean,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_actor uuid;
  v_cached jsonb;
  v_payload jsonb;
  v_account_id uuid;
  v_result jsonb;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  if length(btrim(coalesce(p_account_name,''))) not between 1 and 100
     or p_account_type not in ('cash','mpesa_paybill','bank','cheque_clearing')
     or length(coalesce(p_account_reference,''))>160
     or length(coalesce(p_bank_name,''))>120
     or (p_account_type='bank' and nullif(btrim(p_bank_name),'') is null) then
    raise exception using errcode='22023',message='Invalid receiving account details';
  end if;

  v_payload:=jsonb_build_object(
    'account_id',p_account_id,'account_name',btrim(p_account_name),
    'account_type',p_account_type,'account_reference',p_account_reference,
    'bank_name',p_bank_name,'is_active',coalesce(p_is_active,true)
  );
  v_cached:=private.begin_idempotent_request(p_business_id,'upsert_sales_payment_account',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  if p_account_id is null then
    insert into public.sales_payment_accounts(
      business_id,account_name,account_type,account_reference,bank_name,is_active,created_by
    ) values (
      p_business_id,btrim(p_account_name),p_account_type,
      nullif(btrim(p_account_reference),''),nullif(btrim(p_bank_name),''),
      coalesce(p_is_active,true),v_actor
    ) returning id into v_account_id;
  else
    perform 1 from public.sales_payment_accounts
    where business_id=p_business_id and id=p_account_id
    for update;
    if not found then
      raise exception using errcode='P0002',message='Receiving account not found';
    end if;
    if exists (
      select 1 from public.payments
      where business_id=p_business_id and receiving_account_id=p_account_id
    ) and exists (
      select 1 from public.sales_payment_accounts
      where business_id=p_business_id and id=p_account_id and account_type<>p_account_type
    ) then
      raise exception using errcode='22023',message='Receiving account type cannot change after payments have been recorded';
    end if;
    update public.sales_payment_accounts
    set account_name=btrim(p_account_name),
        account_type=p_account_type,
        account_reference=nullif(btrim(p_account_reference),''),
        bank_name=nullif(btrim(p_bank_name),''),
        is_active=coalesce(p_is_active,true),
        updated_at=now()
    where business_id=p_business_id and id=p_account_id
    returning id into v_account_id;
    if v_account_id is null then
      raise exception using errcode='P0002',message='Receiving account not found';
    end if;
  end if;

  v_result:=jsonb_build_object('account_id',v_account_id,'created',p_account_id is null);
  perform private.finish_idempotent_request(p_business_id,'upsert_sales_payment_account',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,
    case when p_account_id is null then 'sales.payment_account_created' else 'sales.payment_account_updated' end,
    'sales_payment_account',v_account_id,p_request_id,v_payload);
  return v_result;
end;
$function$;

create or replace function public.owner_upsert_sales_payment_account(
  p_business_id uuid,p_account_id uuid,p_account_name text,p_account_type text,
  p_account_reference text,p_bank_name text,p_is_active boolean,p_request_id uuid
) returns jsonb
language sql
security invoker
set search_path=''
as $function$
  select private.owner_upsert_sales_payment_account($1,$2,$3,$4,$5,$6,$7,$8);
$function$;

create or replace function private.owner_record_sales_payment(
  p_business_id uuid,
  p_customer_id uuid,
  p_receiving_account_id uuid,
  p_method text,
  p_amount bigint,
  p_received_at timestamptz,
  p_external_reference text,
  p_allocations jsonb,
  p_notes text,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_actor uuid;
  v_cached jsonb;
  v_payload jsonb;
  v_account public.sales_payment_accounts%rowtype;
  v_customer public.customers%rowtype;
  v_payment_id uuid;
  v_payment_number text;
  v_receipt_number text;
  v_reference text;
  v_duplicate_reference boolean:=false;
  v_allocated_total bigint:=0;
  v_credit_amount bigint:=0;
  v_invoice_id uuid;
  v_allocation_amount bigint;
  v_invoice public.sales_invoices%rowtype;
  v_invoice_paid bigint;
  v_invoice_balance bigint;
  v_item jsonb;
  v_result jsonb;
begin
  v_actor:=private.assert_active_owner(p_business_id);

  if p_method not in ('cash','mpesa_manual','bank_transfer','cheque')
     or p_amount is null or p_amount<=0
     or p_received_at is null or p_received_at>now()+interval '5 minutes'
     or length(coalesce(p_notes,''))>4000
     or jsonb_typeof(coalesce(p_allocations,'[]'::jsonb))<>'array'
     or length(coalesce(p_external_reference,''))>160 then
    raise exception using errcode='22023',message='Invalid payment details';
  end if;

  if (p_method='cash' and nullif(btrim(p_external_reference),'') is not null)
     or (p_method in ('mpesa_manual','bank_transfer','cheque')
         and length(btrim(coalesce(p_external_reference,'')))=0) then
    raise exception using errcode='22023',message='A reference is required for M-Pesa Paybill, bank transfer and cheque; cash must not have one';
  end if;

  if p_method='mpesa_manual' and length(btrim(p_external_reference)) not between 6 and 32 then
    raise exception using errcode='22023',message='M-Pesa Paybill reference must contain 6 to 32 characters';
  end if;

  select * into v_account
  from public.sales_payment_accounts
  where business_id=p_business_id and id=p_receiving_account_id and is_active
  for update;
  if not found then
    raise exception using errcode='P0002',message='Active receiving account not found';
  end if;

  if (p_method='cash' and v_account.account_type<>'cash')
     or (p_method='mpesa_manual' and v_account.account_type<>'mpesa_paybill')
     or (p_method='bank_transfer' and v_account.account_type<>'bank')
     or (p_method='cheque' and v_account.account_type not in ('bank','cheque_clearing')) then
    raise exception using errcode='22023',message='Payment method does not match the selected receiving account';
  end if;

  select * into v_customer
  from public.customers
  where business_id=p_business_id and id=p_customer_id and archived_at is null;
  if not found then
    raise exception using errcode='P0002',message='Active customer not found';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_allocations,'[]'::jsonb)) e(value)
    where jsonb_typeof(e.value)<>'object'
       or coalesce(e.value->>'invoice_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or coalesce(e.value->>'amount','') !~ '^[1-9][0-9]*$'
  ) then
    raise exception using errcode='22023',message='Each allocation must contain a valid invoice_id and positive integer amount';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_allocations,'[]'::jsonb)) e(value)
    group by e.value->>'invoice_id'
    having count(*)>1
  ) then
    raise exception using errcode='22023',message='An invoice may appear only once in a payment allocation request';
  end if;

  v_reference:=case
    when p_method='mpesa_manual' then upper(regexp_replace(btrim(p_external_reference),'[^A-Za-z0-9]','','g'))
    when p_method in ('bank_transfer','cheque') then upper(regexp_replace(btrim(p_external_reference),'[^A-Za-z0-9]','','g'))
    else null
  end;

  if p_method in ('mpesa_manual','bank_transfer','cheque')
     and length(coalesce(v_reference,''))=0 then
    raise exception using errcode='22023',message='Reference must contain letters or numbers';
  end if;
  if p_method='mpesa_manual' and length(coalesce(v_reference,'')) not between 6 and 32 then
    raise exception using errcode='22023',message='M-Pesa Paybill reference must contain 6 to 32 letters or numbers';
  end if;

  if v_reference is not null then
    select exists (
      select 1 from public.payments p
      where p.business_id=p_business_id
        and p.method=p_method
        and (
          (p_method='mpesa_manual' and p.mpesa_reference_normalized=v_reference)
          or (p_method in ('bank_transfer','cheque')
              and p.receiving_account_id=p_receiving_account_id
              and upper(regexp_replace(btrim(coalesce(p.external_reference,'')),'[^A-Za-z0-9]','','g'))=v_reference)
        )
    ) into v_duplicate_reference;
  end if;

  v_payload:=jsonb_build_object(
    'customer_id',p_customer_id,'receiving_account_id',p_receiving_account_id,
    'method',p_method,'amount',p_amount,'received_at',p_received_at,
    'external_reference',p_external_reference,'allocations',coalesce(p_allocations,'[]'::jsonb),
    'notes',p_notes
  );
  v_cached:=private.begin_idempotent_request(p_business_id,'record_sales_payment',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;

  v_payment_number:=private.next_document_number(p_business_id,'payment');
  insert into public.payments(
    business_id,payment_number,method,status,amount,received_at,
    mpesa_reference,mpesa_reference_normalized,external_reference,
    receiving_account_id,intended_order_id,idempotency_key,received_by,notes,duplicate_reference_warning
  ) values (
    p_business_id,v_payment_number,p_method,'posted',p_amount,p_received_at,
    case when p_method='mpesa_manual' then btrim(p_external_reference) else null end,
    case when p_method='mpesa_manual' then v_reference else null end,
    case when p_method in ('bank_transfer','cheque') then btrim(p_external_reference) else null end,
    p_receiving_account_id,null,p_request_id,v_actor,nullif(btrim(p_notes),''),v_duplicate_reference
  ) returning id into v_payment_id;

  insert into public.payment_events(business_id,payment_id,event_type,actor_user_id,metadata)
  values(p_business_id,v_payment_id,'created',v_actor,
    jsonb_build_object('entry_source','manual_sales_entry','method',p_method,'status','posted',
      'duplicate_reference_warning',v_duplicate_reference));

  for v_item in select value from jsonb_array_elements(coalesce(p_allocations,'[]'::jsonb))
  loop
    v_invoice_id:=(v_item->>'invoice_id')::uuid;
    v_allocation_amount:=(v_item->>'amount')::bigint;

    select si.* into v_invoice
    from public.sales_invoices si
    join public.orders o on o.business_id=si.business_id and o.id=si.order_id
    where si.business_id=p_business_id and si.id=v_invoice_id
      and o.customer_id=p_customer_id
    for update of si,o;
    if not found then
      raise exception using errcode='P0002',message='Invoice not found for this customer';
    end if;
    if v_invoice.status not in ('sent','partially_paid','overdue') then
      raise exception using errcode='22023',message='Only issued, unpaid or partially paid invoices can receive payment';
    end if;

    select coalesce(sum(a.amount),0)::bigint
      + coalesce((
        select -sum(e.amount)::bigint
        from public.sales_customer_credit_entries e
        where e.business_id=p_business_id and e.invoice_id=v_invoice_id
          and e.entry_type='apply_to_invoice'
      ),0)
    into v_invoice_paid
    from public.sales_invoice_payment_allocations a
    join public.payments p on p.business_id=a.business_id and p.id=a.payment_id
    where a.business_id=p_business_id and a.invoice_id=v_invoice_id and p.status='posted';

    v_invoice_balance:=greatest(v_invoice.total_amount-v_invoice_paid,0);
    if v_allocation_amount>v_invoice_balance then
      raise exception using errcode='22023',message='Invoice allocation exceeds the outstanding invoice balance';
    end if;

    insert into public.sales_invoice_payment_allocations(
      business_id,invoice_id,payment_id,amount,allocated_by,request_id
    ) values (
      p_business_id,v_invoice_id,v_payment_id,v_allocation_amount,v_actor,p_request_id
    );

    v_allocated_total:=v_allocated_total+v_allocation_amount;
    update public.sales_invoices
    set status=case
      when v_invoice_paid+v_allocation_amount>=v_invoice.total_amount then 'paid'
      when v_invoice_paid+v_allocation_amount>0 then 'partially_paid'
      else status end,
      updated_at=now()
    where business_id=p_business_id and id=v_invoice_id;
  end loop;

  if v_allocated_total>p_amount then
    raise exception using errcode='22023',message='Invoice allocations cannot exceed the recorded payment amount';
  end if;

  v_credit_amount:=p_amount-v_allocated_total;
  if v_credit_amount>0 then
    insert into public.sales_customer_credit_entries(
      business_id,customer_id,entry_type,amount,payment_id,description,actor_user_id,request_id
    ) values (
      p_business_id,p_customer_id,'overpayment',v_credit_amount,v_payment_id,
      case when v_allocated_total=0 then 'Unallocated customer payment credit'
           else 'Payment amount remaining after invoice allocations' end,
      v_actor,p_request_id
    );
  end if;

  v_receipt_number:=private.next_document_number(p_business_id,'receipt');
  insert into public.receipts(
    business_id,receipt_number,payment_id,customer_name_snapshot,amount,issued_by
  ) values (
    p_business_id,v_receipt_number,v_payment_id,v_customer.display_name,p_amount,v_actor
  );

  v_result:=jsonb_build_object(
    'payment_id',v_payment_id,'payment_number',v_payment_number,'status','posted',
    'receipt_number',v_receipt_number,'amount',p_amount,'allocated_amount',v_allocated_total,
    'customer_credit_amount',v_credit_amount,'duplicate_reference_warning',v_duplicate_reference,
    'reconciliation_status','unreconciled','receiving_account_id',p_receiving_account_id,
    'currency_code','KES'
  );
  perform private.finish_idempotent_request(p_business_id,'record_sales_payment',p_request_id,v_result);
  perform private.write_audit(p_business_id,v_actor,'sales.payment_recorded','payment',v_payment_id,p_request_id,
    jsonb_build_object('method',p_method,'amount',p_amount,'customer_id',p_customer_id,
      'receiving_account_id',p_receiving_account_id,'allocated_amount',v_allocated_total,
      'customer_credit_amount',v_credit_amount,'duplicate_reference_warning',v_duplicate_reference));
  return v_result;
end;
$function$;

create or replace function public.owner_record_sales_payment(
  p_business_id uuid,p_customer_id uuid,p_receiving_account_id uuid,p_method text,
  p_amount bigint,p_received_at timestamptz,p_external_reference text,
  p_allocations jsonb,p_notes text,p_request_id uuid
) returns jsonb
language sql
security invoker
set search_path=''
as $function$
  select private.owner_record_sales_payment($1,$2,$3,$4,$5,$6,$7,$8,$9,$10);
$function$;

create or replace function private.owner_reconcile_sales_payment(
  p_payment_id uuid,
  p_reconciliation_date date,
  p_statement_reference text,
  p_notes text,
  p_request_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_payment public.payments%rowtype;
  v_actor uuid;
  v_cached jsonb;
  v_payload jsonb;
  v_reconciliation_id uuid;
  v_result jsonb;
begin
  select * into v_payment from public.payments where id=p_payment_id;
  if not found then
    raise exception using errcode='P0002',message='Payment not found';
  end if;
  v_actor:=private.assert_active_owner(v_payment.business_id);

  if v_payment.receiving_account_id is null
     or p_reconciliation_date is null
     or p_reconciliation_date<(v_payment.received_at at time zone 'Africa/Nairobi')::date
     or p_reconciliation_date>(now() at time zone 'Africa/Nairobi')::date
     or length(coalesce(p_statement_reference,''))>160
     or length(coalesce(p_notes,''))>1000 then
    raise exception using errcode='22023',message='Invalid payment reconciliation details';
  end if;

  v_payload:=jsonb_build_object(
    'payment_id',p_payment_id,'reconciliation_date',p_reconciliation_date,
    'statement_reference',p_statement_reference,'notes',p_notes
  );
  v_cached:=private.begin_idempotent_request(v_payment.business_id,'reconcile_sales_payment',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  if v_payment.status<>'posted' then
    raise exception using errcode='22023',message='Only posted payments can be reconciled';
  end if;

  insert into public.sales_payment_reconciliations(
    business_id,payment_id,receiving_account_id,reconciliation_date,
    statement_reference,notes,reconciled_by,request_id
  ) values (
    v_payment.business_id,v_payment.id,v_payment.receiving_account_id,p_reconciliation_date,
    nullif(btrim(p_statement_reference),''),nullif(btrim(p_notes),''),v_actor,p_request_id
  ) returning id into v_reconciliation_id;

  v_result:=jsonb_build_object(
    'payment_id',p_payment_id,'reconciliation_id',v_reconciliation_id,
    'reconciliation_status','reconciled','reconciliation_date',p_reconciliation_date
  );
  perform private.finish_idempotent_request(v_payment.business_id,'reconcile_sales_payment',p_request_id,v_result);
  perform private.write_audit(v_payment.business_id,v_actor,'sales.payment_reconciled','payment',p_payment_id,p_request_id,
    jsonb_build_object('receiving_account_id',v_payment.receiving_account_id,
      'reconciliation_date',p_reconciliation_date,'statement_reference',p_statement_reference));
  return v_result;
end;
$function$;

create or replace function public.owner_reconcile_sales_payment(
  p_payment_id uuid,p_reconciliation_date date,p_statement_reference text,p_notes text,p_request_id uuid
) returns jsonb
language sql
security invoker
set search_path=''
as $function$
  select private.owner_reconcile_sales_payment($1,$2,$3,$4,$5);
$function$;

revoke all on function private.prevent_sales_payment_reconciliation_mutation() from public,anon,authenticated;
revoke all on function private.owner_upsert_sales_payment_account(uuid,uuid,text,text,text,text,boolean,uuid),
  private.owner_record_sales_payment(uuid,uuid,uuid,text,bigint,timestamptz,text,jsonb,text,uuid),
  private.owner_reconcile_sales_payment(uuid,date,text,text,uuid)
from public,anon,authenticated;
grant execute on function private.owner_upsert_sales_payment_account(uuid,uuid,text,text,text,text,boolean,uuid),
  private.owner_record_sales_payment(uuid,uuid,uuid,text,bigint,timestamptz,text,jsonb,text,uuid),
  private.owner_reconcile_sales_payment(uuid,date,text,text,uuid)
to authenticated;

revoke all on function public.owner_upsert_sales_payment_account(uuid,uuid,text,text,text,text,boolean,uuid),
  public.owner_record_sales_payment(uuid,uuid,uuid,text,bigint,timestamptz,text,jsonb,text,uuid),
  public.owner_reconcile_sales_payment(uuid,date,text,text,uuid)
from public,anon;
grant execute on function public.owner_upsert_sales_payment_account(uuid,uuid,text,text,text,text,boolean,uuid),
  public.owner_record_sales_payment(uuid,uuid,uuid,text,bigint,timestamptz,text,jsonb,text,uuid),
  public.owner_reconcile_sales_payment(uuid,date,text,text,uuid)
to authenticated;

commit;
