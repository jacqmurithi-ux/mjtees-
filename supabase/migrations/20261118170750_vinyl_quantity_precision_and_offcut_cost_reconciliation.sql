-- MJ Tees — recovered applied migration source
-- Version: 20261118170750
-- Name: vinyl_quantity_precision_and_offcut_cost_reconciliation
-- Source: exact SQL statement recovered from live Supabase migration ledger.
-- This file preserves the already-applied migration; do not re-apply to live.
-- Recovery branch only. Review and reconcile migration history before merge.


BEGIN;

ALTER TABLE public.stock_movements
  ALTER COLUMN quantity TYPE numeric(18,9) USING quantity::numeric(18,9);

ALTER TABLE public.production_material_issues
  ALTER COLUMN quantity_issued TYPE numeric(18,9) USING quantity_issued::numeric(18,9);

ALTER TABLE public.production_offcut_returns
  ALTER COLUMN quantity TYPE numeric(18,9) USING quantity::numeric(18,9);

ALTER TABLE public.production_waste
  ALTER COLUMN quantity TYPE numeric(18,9) USING quantity::numeric(18,9);

ALTER TABLE public.stock_reservations
  ALTER COLUMN reserved_quantity TYPE numeric(18,9) USING reserved_quantity::numeric(18,9),
  ALTER COLUMN released_quantity TYPE numeric(18,9) USING released_quantity::numeric(18,9);

CREATE OR REPLACE FUNCTION private.assert_issue_reconciliation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_issue public.production_material_issues%rowtype;
  v_total numeric(18,9);
BEGIN
  SELECT * INTO v_issue
  FROM public.production_material_issues
  WHERE business_id = NEW.business_id
    AND id = NEW.issue_id
  FOR UPDATE;

  IF NOT FOUND OR v_issue.job_id <> NEW.job_id THEN
    RAISE EXCEPTION USING
      errcode = '23514',
      message = 'Waste/offcut must reference an issue from the same production job';
  END IF;

  SELECT
    COALESCE((
      SELECT SUM(w.quantity)
      FROM public.production_waste w
      WHERE w.business_id = NEW.business_id
        AND w.issue_id = NEW.issue_id
    ), 0)
    +
    COALESCE((
      SELECT SUM(o.quantity)
      FROM public.production_offcut_returns o
      WHERE o.business_id = NEW.business_id
        AND o.issue_id = NEW.issue_id
    ), 0)
  INTO v_total;

  IF v_total > v_issue.quantity_issued THEN
    RAISE EXCEPTION USING
      errcode = '23514',
      message = 'Waste plus reusable offcuts cannot exceed issued quantity';
  END IF;

  IF TG_TABLE_NAME = 'production_offcut_returns' THEN
    IF NEW.condition <> 'usable' THEN
      RAISE EXCEPTION USING
        errcode = '23514',
        message = 'Only usable offcuts may be returned to stock; classify damaged offcuts as waste';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.stock_movements m
      WHERE m.business_id = NEW.business_id
        AND m.id = NEW.stock_movement_id
        AND m.movement_type = 'return'
        AND m.stock_item_id = v_issue.stock_item_id
        AND m.location_id = NEW.destination_location_id
        AND m.quantity = NEW.quantity
        AND m.unit_cost_snapshot = v_issue.unit_cost_snapshot
    ) THEN
      RAISE EXCEPTION USING
        errcode = '23514',
        message = 'Offcut return requires one matching positive stock movement';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION private.owner_return_job_offcut(
  p_job_id uuid,
  p_issue_id uuid,
  p_location_id uuid,
  p_quantity numeric,
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_job public.production_jobs%rowtype;
  v_issue public.production_material_issues%rowtype;
  v_actor uuid;
  v_cached jsonb;
  v_payload jsonb;
  v_used numeric(18,9);
  v_returned_before numeric(18,9);
  v_credit_before bigint;
  v_credit_after bigint;
  v_movement uuid;
  v_return uuid;
  v_result jsonb;
BEGIN
  SELECT * INTO v_job
  FROM public.production_jobs
  WHERE id = p_job_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode = 'P0002', message = 'Production job not found';
  END IF;

  v_actor := private.assert_active_owner(v_job.business_id);

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'Positive offcut quantity is required';
  END IF;

  v_payload := jsonb_build_object(
    'job_id', p_job_id,
    'issue_id', p_issue_id,
    'location_id', p_location_id,
    'quantity', p_quantity
  );

  v_cached := private.begin_idempotent_request(
    v_job.business_id, 'return_job_offcut', p_request_id, v_payload
  );

  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  SELECT * INTO v_job
  FROM public.production_jobs
  WHERE business_id = v_job.business_id
    AND id = p_job_id
  FOR UPDATE;

  IF v_job.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'Job is closed to offcut returns';
  END IF;

  SELECT * INTO v_issue
  FROM public.production_material_issues
  WHERE business_id = v_job.business_id
    AND id = p_issue_id
  FOR UPDATE;

  IF NOT FOUND OR v_issue.job_id <> p_job_id THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'Issue does not belong to job';
  END IF;

  SELECT
    COALESCE((SELECT SUM(quantity)
      FROM public.production_waste
      WHERE business_id = v_job.business_id AND issue_id = p_issue_id), 0)
    +
    COALESCE((SELECT SUM(quantity)
      FROM public.production_offcut_returns
      WHERE business_id = v_job.business_id AND issue_id = p_issue_id), 0)
  INTO v_used;

  SELECT COALESCE(SUM(quantity), 0)
  INTO v_returned_before
  FROM public.production_offcut_returns
  WHERE business_id = v_job.business_id
    AND issue_id = p_issue_id;

  IF v_used + p_quantity > v_issue.quantity_issued THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'Offcut return exceeds remaining issued quantity';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.inventory_locations
    WHERE business_id = v_job.business_id
      AND id = p_location_id
      AND is_active
  ) THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'Destination location is invalid';
  END IF;

  v_credit_before := ROUND(v_returned_before * v_issue.unit_cost_snapshot)::bigint;
  v_credit_after := ROUND((v_returned_before + p_quantity) * v_issue.unit_cost_snapshot)::bigint;

  INSERT INTO public.stock_movements(
    business_id, stock_item_id, location_id, movement_type, quantity,
    unit_cost_snapshot, source_type, source_id, reason, actor_user_id, request_id
  )
  VALUES (
    v_job.business_id, v_issue.stock_item_id, p_location_id, 'return', p_quantity,
    v_issue.unit_cost_snapshot, 'production_offcut', p_issue_id,
    'Reusable offcut returned to stock', v_actor, p_request_id
  )
  RETURNING id INTO v_movement;

  INSERT INTO public.production_offcut_returns(
    business_id, job_id, issue_id, quantity, destination_location_id,
    stock_movement_id, condition
  )
  VALUES (
    v_job.business_id, p_job_id, p_issue_id, p_quantity, p_location_id,
    v_movement, 'usable'
  )
  RETURNING id INTO v_return;

  v_result := jsonb_build_object(
    'offcut_return_id', v_return,
    'stock_movement_id', v_movement,
    'quantity', p_quantity,
    'cost_credit', v_credit_after - v_credit_before
  );

  PERFORM private.finish_idempotent_request(
    v_job.business_id, 'return_job_offcut', p_request_id, v_result
  );

  PERFORM private.write_audit(
    v_job.business_id, v_actor, 'production.offcut_returned',
    'production_job', p_job_id, p_request_id,
    jsonb_build_object(
      'issue_id', p_issue_id,
      'quantity', p_quantity,
      'cost_credit', v_credit_after - v_credit_before
    )
  );

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION private.owner_complete_production_job(
  p_job_id uuid,
  p_request_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_job public.production_jobs%rowtype;
  v_actor uuid;
  v_cached jsonb;
  v_payload jsonb;
  v_latest text;
  v_cost bigint;
  v_result jsonb;
  v_order_id uuid;
  v_item_id uuid;
  v_qty numeric;
BEGIN
  SELECT * INTO v_job
  FROM public.production_jobs
  WHERE id = p_job_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode = 'P0002', message = 'Production job not found';
  END IF;

  v_actor := private.assert_active_owner(v_job.business_id);
  v_payload := jsonb_build_object('job_id', p_job_id);

  v_cached := private.begin_idempotent_request(
    v_job.business_id, 'complete_production_job', p_request_id, v_payload
  );

  IF v_cached IS NOT NULL THEN
    RETURN v_cached;
  END IF;

  SELECT * INTO v_job
  FROM public.production_jobs
  WHERE business_id = v_job.business_id
    AND id = p_job_id
  FOR UPDATE;

  IF v_job.status NOT IN ('quality_check', 'in_progress', 'rework') THEN
    RAISE EXCEPTION USING
      errcode = '22023',
      message = 'Job must be in production or quality check before completion';
  END IF;

  SELECT q.result INTO v_latest
  FROM public.quality_checks q
  WHERE q.business_id = v_job.business_id
    AND q.job_id = p_job_id
  ORDER BY q.checked_at DESC, q.id DESC
  LIMIT 1;

  IF v_latest IS DISTINCT FROM 'pass' THEN
    RAISE EXCEPTION USING errcode = '22023', message = 'A latest passing quality check is required';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.quality_checks q
    WHERE q.business_id = v_job.business_id
      AND q.job_id = p_job_id
      AND q.result = 'fail'
      AND NOT EXISTS (
        SELECT 1
        FROM public.rework_events r
        WHERE r.business_id = q.business_id
          AND r.quality_check_id = q.id
          AND r.closed_at IS NOT NULL
      )
  ) THEN
    RAISE EXCEPTION USING
      errcode = '22023',
      message = 'Every failed quality check requires a closed rework event';
  END IF;

  SELECT
    COALESCE(SUM(i.extended_cost), 0)
    - COALESCE((
      SELECT SUM(ROUND(returned.returned_quantity * returned.unit_cost_snapshot)::bigint)
      FROM (
        SELECT
          i2.id AS issue_id,
          i2.unit_cost_snapshot,
          SUM(o.quantity) AS returned_quantity
        FROM public.production_offcut_returns o
        JOIN public.production_material_issues i2
          ON i2.business_id = o.business_id
         AND i2.id = o.issue_id
        WHERE o.business_id = v_job.business_id
          AND o.job_id = p_job_id
        GROUP BY i2.id, i2.unit_cost_snapshot
      ) returned
    ), 0)
    + COALESCE((
      SELECT SUM(c.amount)
      FROM public.production_cost_entries c
      WHERE c.business_id = v_job.business_id
        AND c.job_id = p_job_id
    ), 0)
  INTO v_cost
  FROM public.production_material_issues i
  WHERE i.business_id = v_job.business_id
    AND i.job_id = p_job_id;

  IF v_cost < 0 THEN
    RAISE EXCEPTION USING errcode = '23514', message = 'Calculated job cost cannot be negative';
  END IF;

  UPDATE public.production_jobs
  SET status = 'completed',
      completed_at = now(),
      actual_cost_total = v_cost
  WHERE business_id = v_job.business_id
    AND id = p_job_id;

  SELECT oi.order_id, oi.id, oi.quantity
  INTO v_order_id, v_item_id, v_qty
  FROM public.order_items oi
  WHERE oi.business_id = v_job.business_id
    AND oi.id = v_job.order_item_id;

  UPDATE public.order_items
  SET actual_total_cost = v_cost,
      actual_unit_cost = CASE WHEN v_qty > 0 THEN ROUND(v_cost / v_qty)::bigint ELSE 0 END
  WHERE business_id = v_job.business_id
    AND id = v_item_id;

  IF EXISTS (
    SELECT 1
    FROM public.order_items oi
    WHERE oi.business_id = v_job.business_id
      AND oi.order_id = v_order_id
      AND oi.sale_mode = 'value_added'
      AND oi.production_method_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.production_jobs pj
        WHERE pj.business_id = oi.business_id
          AND pj.order_item_id = oi.id
          AND pj.status = 'completed'
      )
  ) THEN
    RAISE EXCEPTION USING
      errcode = '22023',
      message = 'Every value-added production line must have a completed job';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.production_jobs j
    WHERE j.business_id = v_job.business_id
      AND j.order_item_id IN (
        SELECT oi.id
        FROM public.order_items oi
        WHERE oi.business_id = v_job.business_id
          AND oi.order_id = v_order_id
      )
      AND j.status <> 'completed'
  )
  AND EXISTS (
    SELECT 1
    FROM public.orders
    WHERE business_id = v_job.business_id
      AND id = v_order_id
      AND status = 'in_production'
  ) THEN
    UPDATE public.orders
    SET status = 'ready', updated_at = now()
    WHERE business_id = v_job.business_id
      AND id = v_order_id;

    INSERT INTO public.order_events(
      business_id, order_id, event_type, from_status, to_status,
      actor_user_id, reason
    )
    VALUES (
      v_job.business_id, v_order_id, 'production_ready',
      'in_production', 'ready', v_actor,
      'All production jobs completed and passed QC'
    );
  END IF;

  v_result := jsonb_build_object(
    'job_id', p_job_id,
    'status', 'completed',
    'actual_cost_total', v_cost,
    'order_id', v_order_id
  );

  PERFORM private.finish_idempotent_request(
    v_job.business_id, 'complete_production_job', p_request_id, v_result
  );

  PERFORM private.write_audit(
    v_job.business_id, v_actor, 'production.job_completed',
    'production_job', p_job_id, p_request_id,
    jsonb_build_object('actual_cost_total', v_cost, 'order_id', v_order_id)
  );

  RETURN v_result;
END;
$function$;

COMMIT;
