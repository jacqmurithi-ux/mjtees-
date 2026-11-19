-- Fix supplier price alerts against the live purchase_order_lines schema.
-- The existing table stores item_description, not stock_item_id.
create or replace function public.owner_supplier_price_alerts()
returns jsonb language plpgsql stable security invoker set search_path=public,pg_temp as $fn$
declare v_business uuid; v_result jsonb;
begin
 select business_id into v_business from public.business_memberships
 where user_id=auth.uid() and role='owner' limit 1;
 if v_business is null then raise exception 'Owner workspace required'; end if;
 with ranked as (
  select po.supplier_id,s.supplier_name,si.id stock_item_id,pol.id line_id,pol.unit_cost,
   po.created_at,si.item_name,
   row_number() over(partition by po.supplier_id,si.id
    order by po.created_at desc,po.po_number desc,pol.id desc) rn
  from public.purchase_order_lines pol
  join public.purchase_orders po on po.id=pol.purchase_order_id
  join public.suppliers s on s.id=po.supplier_id
  join public.stock_items si on si.business_id=po.business_id
   and lower(btrim(si.item_name))=lower(btrim(pol.item_description))
  where po.business_id=v_business and po.status<>'cancelled'
 ), pairs as (
  select a.supplier_id,a.supplier_name,a.stock_item_id,a.item_name,
   b.line_id previous_line_id,a.line_id latest_line_id,
   b.unit_cost previous_cost,a.unit_cost latest_cost,a.created_at,
   round(((a.unit_cost-b.unit_cost)/nullif(b.unit_cost,0))*100,2) change_percent
  from ranked a join ranked b on b.supplier_id=a.supplier_id
   and b.stock_item_id=a.stock_item_id and b.rn=2
  where a.rn=1 and a.unit_cost<>b.unit_cost
 )
 select coalesce(jsonb_agg(jsonb_build_object(
  'supplier_id',p.supplier_id,'supplier_name',p.supplier_name,
  'stock_item_id',p.stock_item_id,'item_name',p.item_name,
  'previous_line_id',p.previous_line_id,'latest_line_id',p.latest_line_id,
  'previous_cost',p.previous_cost,'latest_cost',p.latest_cost,
  'change_percent',p.change_percent,'created_at',p.created_at,
  'reviewed',exists(select 1 from public.supplier_price_reviews r
   where r.business_id=v_business and r.previous_line_id=p.previous_line_id
    and r.latest_line_id=p.latest_line_id)
 ) order by p.created_at desc),'[]'::jsonb) into v_result from pairs p;
 return v_result;
end $fn$;

create or replace function public.owner_review_supplier_price_change(
 p_supplier_id uuid,p_stock_item_id uuid,p_previous_line_id uuid,p_latest_line_id uuid
) returns void language plpgsql security definer set search_path=public,pg_temp as $fn$
declare v_business uuid; v_item_name text;
begin
 select business_id into v_business from public.business_memberships
 where user_id=auth.uid() and role='owner' limit 1;
 select item_name into v_item_name from public.stock_items
 where id=p_stock_item_id and business_id=v_business;
 if v_item_name is null then raise exception 'Stock item not found'; end if;
 if not exists(
  select 1 from public.purchase_order_lines a
  join public.purchase_orders pa on pa.id=a.purchase_order_id
  join public.purchase_order_lines b on b.id=p_latest_line_id
  join public.purchase_orders pb on pb.id=b.purchase_order_id
  where a.id=p_previous_line_id and pa.supplier_id=p_supplier_id
   and pb.supplier_id=p_supplier_id
   and lower(btrim(a.item_description))=lower(btrim(v_item_name))
   and lower(btrim(b.item_description))=lower(btrim(v_item_name))
   and pa.business_id=v_business and pb.business_id=v_business
 ) then raise exception 'Price change record not found'; end if;
 insert into public.supplier_price_reviews(
  business_id,supplier_id,stock_item_id,previous_line_id,latest_line_id,reviewed_by
 ) values(v_business,p_supplier_id,p_stock_item_id,p_previous_line_id,p_latest_line_id,auth.uid())
 on conflict do nothing;
end $fn$;
revoke all on function public.owner_supplier_price_alerts() from public,anon;
revoke all on function public.owner_review_supplier_price_change(uuid,uuid,uuid,uuid) from public,anon;
grant execute on function public.owner_supplier_price_alerts() to authenticated;
grant execute on function public.owner_review_supplier_price_change(uuid,uuid,uuid,uuid) to authenticated;