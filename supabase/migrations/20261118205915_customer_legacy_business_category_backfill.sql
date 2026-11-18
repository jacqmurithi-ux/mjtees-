update public.customers set customer_type='business' where customer_type='individual' and nullif(btrim(business_name),'') is not null and archived_at is null;
