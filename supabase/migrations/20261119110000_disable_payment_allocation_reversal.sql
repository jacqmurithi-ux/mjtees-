-- MJ Tees: disable the remaining legacy payment-allocation reversal RPCs.
-- Keep historical allocation_reversals rows for audit; do not expose a reversal action.
begin;

drop function if exists public.owner_reverse_payment_allocation(uuid,bigint,text,uuid);
drop function if exists private.owner_reverse_payment_allocation(uuid,bigint,text,uuid);

commit;
