-- Payment reversal is not supported in MJ Tees.
-- Legacy refunds remain a separate, audited workflow.
begin;
drop function if exists public.owner_reverse_payment(uuid,text,uuid);
drop function if exists private.owner_reverse_payment(uuid,text,uuid);
commit;
