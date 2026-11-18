-- Milestone 08 turnaround and production workload reporting.
create index if not exists order_events_business_occurred_at_idx on public.order_events(business_id,occurred_at);
create index if not exists production_jobs_business_completed_at_idx on public.production_jobs(business_id,completed_at);
create index if not exists deliveries_business_handed_over_idx on public.deliveries(business_id,handed_over_at);

create or replace function public.owner_get_daily_operations_summary(p_business_id uuid,p_business_date date)
returns jsonb language plpgsql security invoker set search_path=''
as $$
declare v_actor uuid; v_result jsonb; v_start timestamptz; v_end timestamptz;
begin
  v_actor:=private.assert_active_owner(p_business_id);
  if p_business_date is null then raise exception using errcode='22023',message='Business date is required'; end if;
  v_start:=p_business_date::timestamp at time zone 'Africa/Nairobi';
  v_end:=(p_business_date+1)::timestamp at time zone 'Africa/Nairobi';
  select jsonb_build_object(
    'business_date',p_business_date,
    'orders_in_progress',(select count(*) from public.orders o where o.business_id=p_business_id and o.status in ('confirmed','in_production','quality_check')),
    'ready_awaiting_collection',(select count(*) from public.orders o where o.business_id=p_business_id and o.status='ready'
      and not exists(select 1 from public.deliveries d where d.business_id=o.business_id and d.order_id=o.id and d.handed_over_at is not null)
      and not exists(select 1 from public.deliveries d where d.business_id=o.business_id and d.order_id=o.id and d.method='courier' and d.attempt_status='dispatched')),
    'courier_outstanding',(select count(*) from public.deliveries d where d.business_id=p_business_id and d.method='courier' and d.attempt_status='dispatched'),
    'failed_delivery_attempts',(select count(*) from public.deliveries d where d.business_id=p_business_id and d.attempt_status='failed'),
    'overdue_orders',(select count(*) from public.orders o where o.business_id=p_business_id and o.required_by<p_business_date and o.status not in ('completed','cancelled')),
    'pending_mpesa',(select count(*) from public.payments p where p.business_id=p_business_id and p.method='mpesa_manual' and p.status='pending_verification'),
    'outstanding_balances',(select coalesce(sum(greatest(o.total_amount-coalesce(b.net_paid,0),0)),0)
      from public.orders o left join lateral (
        select coalesce(sum(a.amount
          - coalesce((select sum(ar.amount) from public.allocation_reversals ar where ar.business_id=a.business_id and ar.allocation_id=a.id),0)
          - coalesce((select sum(rf.amount) from public.payment_refunds rf where rf.business_id=a.business_id and rf.allocation_id=a.id and rf.status='posted'),0)
        ),0)::bigint net_paid
        from public.payment_allocations a join public.payments pay on pay.business_id=a.business_id and pay.id=a.payment_id and pay.status='posted'
        where a.business_id=o.business_id and a.order_id=o.id
      ) b on true where o.business_id=p_business_id and o.status not in ('completed','cancelled')),
    'production_workload',(select count(*) from public.production_jobs j where j.business_id=p_business_id and j.status not in ('completed','cancelled')),
    'avg_production_hours',(select round(avg(extract(epoch from (j.completed_at-j.started_at))/3600)::numeric,2)
      from public.production_jobs j where j.business_id=p_business_id and j.started_at is not null and j.completed_at>=v_start and j.completed_at<v_end),
    'avg_ready_turnaround_hours',(select round(avg(extract(epoch from (e.occurred_at-o.received_at))/3600)::numeric,2)
      from public.order_events e join public.orders o on o.business_id=e.business_id and o.id=e.order_id
      where e.business_id=p_business_id and e.event_type='marked_ready' and e.occurred_at>=v_start and e.occurred_at<v_end),
    'avg_customer_turnaround_hours',(select round(avg(extract(epoch from (d.handed_over_at-o.received_at))/3600)::numeric,2)
      from public.deliveries d join public.orders o on o.business_id=d.business_id and o.id=d.order_id
      where d.business_id=p_business_id and d.handed_over_at>=v_start and d.handed_over_at<v_end),
    'on_time_handovers',(select count(*) from public.deliveries d join public.orders o on o.business_id=d.business_id and o.id=d.order_id
      where d.business_id=p_business_id and d.handed_over_at>=v_start and d.handed_over_at<v_end and o.required_by is not null
        and (d.handed_over_at at time zone 'Africa/Nairobi')::date<=o.required_by),
    'late_handovers',(select count(*) from public.deliveries d join public.orders o on o.business_id=d.business_id and o.id=d.order_id
      where d.business_id=p_business_id and d.handed_over_at>=v_start and d.handed_over_at<v_end and o.required_by is not null
        and (d.handed_over_at at time zone 'Africa/Nairobi')::date>o.required_by),
    'order_value',(select coalesce(sum(o.total_amount),0) from public.orders o where o.business_id=p_business_id and o.received_at>=v_start and o.received_at<v_end and o.status<>'cancelled'),
    'posted_receipts',(select coalesce(sum(p.amount),0) from public.payments p where p.business_id=p_business_id and p.status='posted' and p.received_at>=v_start and p.received_at<v_end),
    'posted_refunds',(select coalesce(sum(f.amount),0) from public.payment_refunds f where f.business_id=p_business_id and f.status='posted' and f.posted_at>=v_start and f.posted_at<v_end),
    'expenses',(select coalesce(sum(e.amount),0) from public.expenses e where e.business_id=p_business_id and e.expense_date=p_business_date),
    'cash_expenses',(select coalesce(sum(e.amount),0) from public.expenses e where e.business_id=p_business_id and e.expense_date=p_business_date and e.payment_method='cash'),
    'production_costs',(select coalesce(sum(c.amount),0) from public.production_cost_entries c where c.business_id=p_business_id and c.occurred_at>=v_start and c.occurred_at<v_end),
    'daily_closing',(select to_jsonb(dc) from public.daily_closings dc where dc.business_id=p_business_id and dc.business_date=p_business_date),
    'daily_closing_adjustments',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at), '[]'::jsonb) from public.daily_closing_adjustments a join public.daily_closings dc on dc.id=a.daily_closing_id where a.business_id=p_business_id and dc.business_date=p_business_date),
    'mpesa_reconciliation',(select to_jsonb(r) from public.daily_payment_reconciliations r where r.business_id=p_business_id and r.business_date=p_business_date and r.method='mpesa'),
    'reconciliation_adjustments',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at), '[]'::jsonb) from public.daily_payment_reconciliation_adjustments a join public.daily_payment_reconciliations r on r.id=a.reconciliation_id where a.business_id=p_business_id and r.business_date=p_business_date and r.method='mpesa')
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function public.owner_get_daily_operations_summary(uuid,date) from public,anon;
grant execute on function public.owner_get_daily_operations_summary(uuid,date) to authenticated;
