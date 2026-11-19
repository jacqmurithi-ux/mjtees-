-- Remove a recursive, unused helper that could otherwise be invoked directly.
-- Payment recording now updates invoice balances only inside the owner-checked
-- private.owner_record_payment_impl transaction.
revoke all on function private.update_invoice_balance(uuid,uuid,numeric) from public,anon,authenticated;
drop function if exists private.update_invoice_balance(uuid,uuid,numeric);
