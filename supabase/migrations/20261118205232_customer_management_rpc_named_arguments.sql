CREATE OR REPLACE FUNCTION public.owner_get_or_create_walk_in_customer(p_business_id uuid, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.owner_get_or_create_walk_in_customer($1,$2); $function$


CREATE OR REPLACE FUNCTION public.owner_record_customer_interaction(p_business_id uuid, p_customer_id uuid, p_interaction_type text, p_subject text, p_notes text, p_follow_up_at timestamp with time zone, p_outcome text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.owner_record_customer_interaction($1,$2,$3,$4,$5,$6,$7,$8); $function$


CREATE OR REPLACE FUNCTION public.owner_record_customer_reward(p_business_id uuid, p_customer_id uuid, p_rule_id uuid, p_order_id uuid, p_entry_type text, p_reward_kind text, p_amount bigint, p_reason text, p_reference text, p_reverses_entry_id uuid, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.owner_record_customer_reward($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11); $function$


CREATE OR REPLACE FUNCTION public.owner_save_customer_profile(p_business_id uuid, p_customer_id uuid, p_display_name text, p_business_name text, p_customer_type text, p_phone text, p_email text, p_location text, p_registration_number text, p_preferred_contact_method text, p_customer_status text, p_notes text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.owner_save_customer_profile($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13); $function$


CREATE OR REPLACE FUNCTION public.owner_upsert_customer_contact(p_business_id uuid, p_contact_id uuid, p_customer_id uuid, p_full_name text, p_position_title text, p_phone text, p_email text, p_is_primary boolean, p_can_place_orders boolean, p_can_approve_quotes boolean, p_can_collect_orders boolean, p_is_active boolean, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.owner_upsert_customer_contact($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13); $function$


CREATE OR REPLACE FUNCTION public.owner_upsert_customer_loyalty_rule(p_business_id uuid, p_rule_id uuid, p_name text, p_customer_type text, p_reward_event text, p_reward_kind text, p_calculation_method text, p_reward_value bigint, p_minimum_order_amount bigint, p_minimum_order_count integer, p_applies_to text, p_is_active boolean, p_starts_on date, p_ends_on date, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO ''
AS $function$ select private.owner_upsert_customer_loyalty_rule($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15); $function$

