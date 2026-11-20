-- Multi-line quotation engine for MJ Printing & Branding.
-- Keeps all pricing, costing and discount decisions server-side. No prices or rates are seeded.
alter table public.quotations
 add column if not exists revision_number integer not null default 1,
 add column if not exists revision_reason text,
 add column if not exists supersedes_quotation_id uuid references public.quotations(id),
 add column if not exists accepted_at timestamptz,
 add column if not exists accepted_recorded_by uuid references auth.users(id);

alter table public.quotation_lines
 add column if not exists catalogue_item_id uuid,
 add column if not exists production_method text,
 add column if not exists costing_profile_id uuid references public.costing_profiles(id),
 add column if not exists supply_arrangement text not null default 'mj_supplies'
   check (supply_arrangement in ('mj_supplies','customer_supplies')),
 add column if not exists standard_unit_price numeric(14,2),
 add column if not exists discount_type text not null default 'none'
   check (discount_type in ('none','fixed_amount','percentage')),
 add column if not exists discount_value numeric(14,2) not null default 0 check(discount_value>=0),
 add column if not exists discount_amount numeric(14,2) not null default 0 check(discount_amount>=0),
 add column if not exists net_unit_price numeric(14,2),
 add column if not exists gross_margin_percent numeric(7,2),
 add column if not exists discount_reason text,
 add column if not exists below_floor_exception_reason text,
 add column if not exists cost_snapshot jsonb not null default '{}'::jsonb;

alter table public.quotation_lines
 add constraint quotation_lines_catalogue_item_fk
 foreign key (business_id,catalogue_item_id)
 references public.catalogue_items(business_id,id) on delete restrict;

create table if not exists public.quotation_revision_history (
 id uuid primary key default gen_random_uuid(),
 business_id uuid not null references public.businesses(id) on delete cascade,
 quotation_id uuid not null references public.quotations(id) on delete restrict,
 revision_number integer not null check(revision_number>=1),
 revision_reason text not null,
 snapshot jsonb not null check(jsonb_typeof(snapshot)='object'),
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 unique(business_id,quotation_id,revision_number)
);
alter table public.quotation_revision_history enable row level security;
drop policy if exists quotation_revision_history_owner_read on public.quotation_revision_history;
create policy quotation_revision_history_owner_read on public.quotation_revision_history
 for select to authenticated using(exists(
  select 1 from public.business_memberships bm where bm.business_id=quotation_revision_history.business_id
   and bm.user_id=auth.uid() and bm.role='owner'
 ));
revoke all on public.quotation_revision_history from anon,authenticated;
grant select on public.quotation_revision_history to authenticated;

create or replace function private.owner_create_quotation_v2_impl(
 p_customer_id uuid,p_quote_number text,p_valid_until date,p_lines jsonb,
 p_allow_below_floor boolean default false,p_exception_reason text default null
) returns uuid
language plpgsql security definer set search_path=public,private,pg_temp
as $fn$
declare
 v_business uuid; v_user uuid; v_quote uuid; v_line jsonb; v_item uuid;
 v_method text; v_profile uuid; v_profile_name text; v_profile_version integer; v_components jsonb;
 v_qty numeric(14,3); v_standard numeric(14,2); v_discount_type text; v_discount_value numeric(14,2);
 v_discount numeric(14,2); v_unit_net numeric(14,2); v_total numeric(14,2); v_cost numeric(14,2);
 v_component jsonb; v_component_cost numeric(14,2); v_basis text; v_category text;
 v_customer_supplied boolean; v_blank_override numeric(14,2); v_other numeric(14,2);
 v_breakdown jsonb; v_snapshot jsonb; v_margin numeric(7,2); v_desc text;
 v_line_total numeric(14,2); v_discount_reason text; v_lines_total numeric(14,2):=0;
 v_all_cost numeric(14,2):=0; v_max_price numeric(14,2); v_line_count integer:=0;
begin
 v_user:=auth.uid();
 select business_id into v_business from public.business_memberships
 where user_id=v_user and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 if not exists(select 1 from public.customers where id=p_customer_id and business_id=v_business) then
  raise exception 'Customer not found in this workspace';
 end if;
 if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)<1 then
  raise exception 'At least one quotation line is required';
 end if;
 select max_unit_selling_price into v_max_price from public.business_settings where business_id=v_business;

 insert into public.quotations(business_id,customer_id,quote_number,valid_until,total,created_by,status)
 values(v_business,p_customer_id,btrim(p_quote_number),p_valid_until,0,v_user,'accepted')
 returning id into v_quote;

 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_line_count:=v_line_count+1;
  v_item:=nullif(v_line->>'catalogue_item_id','')::uuid;
  v_method:=nullif(btrim(v_line->>'production_method'),'');
  v_profile:=nullif(v_line->>'costing_profile_id','')::uuid;
  v_qty:=nullif(v_line->>'quantity','')::numeric;
  v_standard:=nullif(v_line->>'unit_price','')::numeric;
  v_desc:=btrim(coalesce(v_line->>'description',''));
  if v_desc='' or v_qty is null or v_qty<=0 or v_standard is null or v_standard<0 then
   raise exception 'Each quotation line requires a description, positive quantity and non-negative approved unit price';
  end if;
  if v_max_price is not null and v_standard>v_max_price then
   raise exception 'Unit selling price exceeds the owner-set maximum price of KSh %',v_max_price;
  end if;
  if v_item is not null and not exists(select 1 from public.catalogue_items ci
    where ci.id=v_item and ci.business_id=v_business and ci.is_active) then
   raise exception 'Catalogue item is inactive or does not belong to this workspace';
  end if;
  if v_item is not null and not exists(select 1 from public.catalogue_item_methods cm
    where cm.business_id=v_business and cm.catalogue_item_id=v_item and cm.is_active
     and (v_method is null or cm.production_method=v_method)) and v_method is not null then
   raise exception 'Selected production method is not active for this catalogue item';
  end if;
  if v_method is not null and v_method not in('sublimation','dtf','screen_printing','embroidery','vinyl_cutting','other') then
   raise exception 'Unsupported production method';
  end if;
  v_customer_supplied:=coalesce(v_line->>'supply_arrangement','mj_supplies')='customer_supplies';
  if coalesce(v_line->>'supply_arrangement','mj_supplies') not in('mj_supplies','customer_supplies') then
   raise exception 'Invalid supply arrangement';
  end if;
  v_discount_type:=coalesce(nullif(v_line->>'discount_type',''),'none');
  v_discount_value:=coalesce(nullif(v_line->>'discount_value','')::numeric,0);
  v_discount_reason:=nullif(btrim(v_line->>'discount_reason'),'');
  if v_discount_type not in('none','fixed_amount','percentage') or v_discount_value<0 then
   raise exception 'Invalid line discount';
  end if;
  if v_discount_type='none' and v_discount_value<>0 then raise exception 'A discount value requires a discount type'; end if;
  if v_discount_type<>'none' and coalesce(length(v_discount_reason),0)<3 then
   raise exception 'A reason is required for every discretionary line discount';
  end if;
  if v_discount_type='percentage' and v_discount_value>100 then raise exception 'Percentage discount cannot exceed 100';
  end if;
  v_discount:=case when v_discount_type='fixed_amount' then v_discount_value
    when v_discount_type='percentage' then round(v_standard*v_discount_value/100,2) else 0 end;
  if v_discount>v_standard then raise exception 'Line discount cannot exceed its standard unit price';
  end if;
  v_unit_net:=v_standard-v_discount;
  v_line_total:=round(v_unit_net*v_qty,2);
  v_cost:=0; v_breakdown:='[]'::jsonb; v_snapshot:='{}'::jsonb;
  v_blank_override:=nullif(v_line->>'blank_cost_per_piece','')::numeric;
  v_other:=coalesce(nullif(v_line->>'other_costs_total','')::numeric,0);
  if coalesce(v_blank_override,0)<0 or v_other<0 then raise exception 'Direct costs cannot be negative'; end if;

  if v_profile is not null then
   select cp.profile_name,cp.version,cp.components into v_profile_name,v_profile_version,v_components
   from public.costing_profiles cp where cp.id=v_profile and cp.business_id=v_business and cp.is_active for share;
   if v_profile_name is null then raise exception 'Costing profile must be active and belong to this business'; end if;
   if jsonb_typeof(v_components)<>'array' then raise exception 'Costing profile components are invalid'; end if;
   for v_component in select value from jsonb_array_elements(v_components) loop
    v_category:=coalesce(v_component->>'category','production');
    v_basis:=coalesce(v_component->>'basis','per_piece');
    v_component_cost:=coalesce(nullif(v_component->>'cost','')::numeric,0);
    if v_component_cost<0 or v_basis not in('per_piece','per_job') then raise exception 'Invalid costing component'; end if;
    if v_category='blank_item' and (v_customer_supplied or (v_blank_override is not null and v_basis='per_piece')) then continue; end if;
    if v_category not in('blank_item','production') then raise exception 'Invalid costing category'; end if;
    v_cost:=v_cost+case when v_basis='per_job' then v_component_cost else v_component_cost*v_qty end;
    v_breakdown:=v_breakdown||jsonb_build_array(jsonb_build_object(
     'name',v_component->>'name','category',v_category,'basis',v_basis,'unit_cost',v_component_cost,
     'quantity',case when v_basis='per_job' then 1 else v_qty end,
     'total_cost',case when v_basis='per_job' then v_component_cost else v_component_cost*v_qty end));
   end loop;
  elsif coalesce(v_line->>'selling_method','')<>'fixed_price' then
   raise exception 'A costing profile is required for job-costed or quantity-tier lines';
  end if;
  if not v_customer_supplied and v_blank_override is not null then
   v_cost:=v_cost+(v_blank_override*v_qty);
   v_breakdown:=v_breakdown||jsonb_build_array(jsonb_build_object('name','Blank item override','category','blank_item','basis','per_piece','unit_cost',v_blank_override,'quantity',v_qty,'total_cost',v_blank_override*v_qty));
  end if;
  if v_other>0 then v_cost:=v_cost+v_other; v_breakdown:=v_breakdown||jsonb_build_array(jsonb_build_object('name',coalesce(v_line->>'other_costs_note','Other direct costs'),'basis','per_job','unit_cost',v_other,'quantity',1,'total_cost',v_other)); end if;
  v_margin:=case when v_line_total>0 then round(((v_line_total-v_cost)/v_line_total)*100,2) else case when v_cost=0 then 100 else -100 end end;
  if v_cost>0 and v_margin<30 then
   if not coalesce(p_allow_below_floor,false) or length(btrim(coalesce(p_exception_reason,'')))<8 then
    raise exception 'Quotation line % is below the 30%% gross-margin floor. An authorised exception and reason are required',v_line_count;
   end if;
  end if;
  v_snapshot:=jsonb_build_object('profile_id',v_profile,'profile_name',v_profile_name,'profile_version',v_profile_version,
   'quantity',v_qty,'supply_arrangement',case when v_customer_supplied then 'customer_supplies' else 'mj_supplies' end,
   'components',v_breakdown,'direct_cost_total',round(v_cost,2),'gross_margin_percent',v_margin,
   'catalogue_item_id',v_item,'production_method',v_method,'standard_unit_price',v_standard,
   'discount_type',v_discount_type,'discount_value',v_discount_value,'discount_amount_per_unit',v_discount,
   'net_unit_price',v_unit_net);
  insert into public.quotation_lines(business_id,quotation_id,catalogue_item_id,description,quantity,unit_price,
   standard_unit_price,direct_cost,line_total,production_method,costing_profile_id,
   supply_arrangement,discount_type,discount_value,discount_amount,net_unit_price,gross_margin_percent,
   discount_reason,below_floor_exception_reason,cost_snapshot,details)
  values(v_business,v_quote,v_item,v_desc,v_qty,v_unit_net,v_standard,round(v_cost,2),v_line_total,
   v_method,v_profile,case when v_customer_supplied then 'customer_supplies' else 'mj_supplies' end,
   v_discount_type,v_discount_value,round(v_discount*v_qty,2),v_unit_net,v_margin,v_discount_reason,
   case when v_cost>0 and v_margin<30 then btrim(p_exception_reason) end,v_snapshot,
   coalesce(v_line->'details','{}'::jsonb)||jsonb_build_object('cost_snapshot',v_snapshot));
  v_lines_total:=v_lines_total+v_line_total; v_all_cost:=v_all_cost+v_cost;
 end loop;
 if v_line_count=0 then raise exception 'At least one quotation line is required'; end if;
 update public.quotations set total=round(v_lines_total,2),accepted_at=now(),accepted_recorded_by=v_user
 where id=v_quote;
 insert into public.quotation_revision_history(business_id,quotation_id,revision_number,revision_reason,snapshot,created_by)
 select v_business,v_quote,1,'Initial accepted quotation',jsonb_build_object(
  'quote_number',p_quote_number,'customer_id',p_customer_id,'total',round(v_lines_total,2),
  'line_count',v_line_count,'direct_cost_total',round(v_all_cost,2),
  'lines',(select coalesce(jsonb_agg(to_jsonb(ql) order by ql.id),'[]'::jsonb) from public.quotation_lines ql where ql.quotation_id=v_quote)),v_user;
 insert into public.audit_events(business_id,actor_user_id,event_type,entity_type,entity_id,details)
 values(v_business,v_user,'quotation.accepted_created','quotation',v_quote,
  jsonb_build_object('total',round(v_lines_total,2),'line_count',v_line_count,'direct_cost_total',round(v_all_cost,2)));
 return v_quote;
end $fn$;

create or replace function public.owner_create_accepted_quotation(
 p_customer_id uuid,p_quote_number text,p_valid_until date,p_lines jsonb,
 p_allow_below_floor boolean default false,p_exception_reason text default null
) returns uuid language sql security invoker set search_path=public,private,pg_temp
as $fn$ select private.owner_create_quotation_v2_impl(
 p_customer_id,p_quote_number,p_valid_until,p_lines,p_allow_below_floor,p_exception_reason) $fn$;

revoke all on function private.owner_create_quotation_v2_impl(uuid,text,date,jsonb,boolean,text) from public,anon,authenticated;
revoke all on function public.owner_create_accepted_quotation(uuid,text,date,jsonb,boolean,text) from public,anon;
grant execute on function public.owner_create_accepted_quotation(uuid,text,date,jsonb,boolean,text) to authenticated;

notify pgrst,'reload schema';

-- Revision snapshots are append-only audit evidence.
create or replace function private.reject_quotation_revision_history_mutation()
returns trigger language plpgsql set search_path=public,pg_temp
as $fn$
begin
 raise exception 'Quotation revision history is immutable';
end $fn$;
drop trigger if exists quotation_revision_history_immutable on public.quotation_revision_history;
create trigger quotation_revision_history_immutable
 before update or delete on public.quotation_revision_history
 for each row execute function private.reject_quotation_revision_history_mutation();

revoke insert,update,delete on public.quotation_revision_history from anon,authenticated;
