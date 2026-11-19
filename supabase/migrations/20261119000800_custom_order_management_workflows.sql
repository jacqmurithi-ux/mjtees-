-- Owner-controlled custom-order detail workflows.
-- Adds transactional RPCs for job sizes, artwork proof versions and colour separations.
begin;

create or replace function private.owner_add_job_size_breakdown(
  p_job_id uuid,p_person_name text,p_jersey_number text,p_size text,p_colour text,
  p_quantity numeric,p_notes text,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_job public.production_jobs%rowtype;
  v_actor uuid;
  v_payload jsonb;
  v_cached jsonb;
  v_id uuid;
  v_result jsonb;
begin
  select * into v_job from public.production_jobs where id=p_job_id;
  if not found then raise exception using errcode='P0002',message='Production job not found'; end if;
  v_actor:=private.assert_active_owner(v_job.business_id);
  if p_request_id is null
    or length(btrim(coalesce(p_person_name,''))) not between 1 and 180
    or length(btrim(coalesce(p_size,''))) not between 1 and 40
    or p_quantity is null or p_quantity<=0 or p_quantity<>round(p_quantity,3)
    or length(coalesce(p_jersey_number,''))>40
    or length(coalesce(p_colour,''))>80
    or length(coalesce(p_notes,''))>1000 then
    raise exception using errcode='22023',message='Enter a valid name, size, quantity and optional garment details';
  end if;
  if v_job.status in ('completed','cancelled') then
    raise exception using errcode='55000',message='A completed or cancelled job cannot be changed';
  end if;
  v_payload:=jsonb_build_object('job_id',p_job_id,'person_name',btrim(p_person_name),
    'jersey_number',nullif(btrim(p_jersey_number),''),'size',btrim(p_size),
    'colour',nullif(btrim(p_colour),''),'quantity',p_quantity,'notes',nullif(btrim(p_notes),''));
  v_cached:=private.begin_idempotent_request(v_job.business_id,'add_job_size_breakdown',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  insert into public.sales_job_size_breakdown(
    business_id,job_id,person_name,jersey_number,size,colour,quantity,notes
  ) values (
    v_job.business_id,p_job_id,btrim(p_person_name),nullif(btrim(p_jersey_number),''),
    btrim(p_size),nullif(btrim(p_colour),''),p_quantity,nullif(btrim(p_notes),'')
  ) returning id into v_id;
  v_result:=jsonb_build_object('size_breakdown_id',v_id,'job_id',p_job_id);
  perform private.finish_idempotent_request(v_job.business_id,'add_job_size_breakdown',p_request_id,v_result);
  perform private.write_audit(v_job.business_id,v_actor,'custom_order.size_added','sales_job_size_breakdown',v_id,p_request_id,v_result);
  return v_result;
end;
$$;

create or replace function private.owner_add_job_artwork(
  p_job_id uuid,p_storage_path text,p_file_name text,p_notes text,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_job public.production_jobs%rowtype;
  v_actor uuid;
  v_payload jsonb;
  v_cached jsonb;
  v_version integer;
  v_id uuid;
  v_result jsonb;
begin
  select * into v_job from public.production_jobs where id=p_job_id for update;
  if not found then raise exception using errcode='P0002',message='Production job not found'; end if;
  v_actor:=private.assert_active_owner(v_job.business_id);
  if p_request_id is null
    or p_storage_path is null or p_storage_path !~ '^https://(drive|docs)\\.google\\.com/'
    or length(btrim(coalesce(p_file_name,''))) not between 1 and 255
    or length(coalesce(p_notes,''))>1000 then
    raise exception using errcode='22023',message='Provide a Google Drive artwork link, file name and valid notes';
  end if;
  if v_job.status in ('completed','cancelled') then
    raise exception using errcode='55000',message='A completed or cancelled job cannot receive a new artwork version';
  end if;
  v_payload:=jsonb_build_object('job_id',p_job_id,'storage_path',btrim(p_storage_path),
    'file_name',btrim(p_file_name),'notes',nullif(btrim(p_notes),''));
  v_cached:=private.begin_idempotent_request(v_job.business_id,'add_job_artwork',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_job.business_id::text||':'||p_job_id::text,0));
  select coalesce(max(version),0)+1 into v_version
  from public.sales_job_artworks where business_id=v_job.business_id and job_id=p_job_id;
  update public.sales_job_artworks
    set proof_status='superseded'
    where business_id=v_job.business_id and job_id=p_job_id
      and proof_status in ('pending','sent','rejected');
  insert into public.sales_job_artworks(
    business_id,job_id,storage_path,file_name,version,proof_status,notes,created_by
  ) values (
    v_job.business_id,p_job_id,btrim(p_storage_path),btrim(p_file_name),v_version,'pending',
    nullif(btrim(p_notes),''),v_actor
  ) returning id into v_id;
  v_result:=jsonb_build_object('artwork_id',v_id,'job_id',p_job_id,'version',v_version,'proof_status','pending');
  perform private.finish_idempotent_request(v_job.business_id,'add_job_artwork',p_request_id,v_result);
  perform private.write_audit(v_job.business_id,v_actor,'custom_order.artwork_version_added','sales_job_artwork',v_id,p_request_id,v_result);
  return v_result;
end;
$$;

create or replace function private.owner_set_job_artwork_status(
  p_artwork_id uuid,p_proof_status text,p_approved_by_contact_id uuid,p_notes text,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_artwork public.sales_job_artworks%rowtype;
  v_actor uuid;
  v_payload jsonb;
  v_cached jsonb;
  v_result jsonb;
begin
  select * into v_artwork from public.sales_job_artworks where id=p_artwork_id for update;
  if not found then raise exception using errcode='P0002',message='Artwork proof not found'; end if;
  v_actor:=private.assert_active_owner(v_artwork.business_id);
  if p_request_id is null or p_proof_status is null or p_proof_status not in ('sent','approved','rejected')
    or length(coalesce(p_notes,''))>1000 then
    raise exception using errcode='22023',message='Choose a valid proof status and request id';
  end if;
  v_payload:=jsonb_build_object('artwork_id',p_artwork_id,'proof_status',p_proof_status,
    'approved_by_contact_id',p_approved_by_contact_id,'notes',nullif(btrim(p_notes),''));
  v_cached:=private.begin_idempotent_request(v_artwork.business_id,'set_job_artwork_status',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  if p_proof_status='sent' and v_artwork.proof_status not in ('pending') then
    raise exception using errcode='55000',message='Only a pending proof can be marked as sent; create a new version after rejection';
  end if;
  if p_proof_status in ('approved','rejected') and v_artwork.proof_status<>'sent' then
    raise exception using errcode='55000',message='Only a sent proof can be approved or rejected';
  end if;
  if p_approved_by_contact_id is not null and not exists(
    select 1 from public.customer_contacts c
    where c.business_id=v_artwork.business_id and c.id=p_approved_by_contact_id
  ) then
    raise exception using errcode='22023',message='Approval contact does not belong to this business';
  end if;
  update public.sales_job_artworks
    set proof_status=p_proof_status,
      sent_at=case when p_proof_status='sent' then coalesce(sent_at,now()) else sent_at end,
      approved_at=case when p_proof_status='approved' then now() else approved_at end,
      approved_by_contact_id=case when p_proof_status='approved' then p_approved_by_contact_id else approved_by_contact_id end,
      notes=coalesce(nullif(btrim(p_notes),''),notes)
    where business_id=v_artwork.business_id and id=p_artwork_id;
  v_result:=jsonb_build_object('artwork_id',p_artwork_id,'proof_status',p_proof_status);
  perform private.finish_idempotent_request(v_artwork.business_id,'set_job_artwork_status',p_request_id,v_result);
  perform private.write_audit(v_artwork.business_id,v_actor,'custom_order.artwork_status_changed','sales_job_artwork',p_artwork_id,p_request_id,v_result);
  return v_result;
end;
$$;

create or replace function private.owner_add_job_colour_separation(
  p_job_id uuid,p_artwork_id uuid,p_colour_name text,p_ink_reference text,p_screen_reference text,
  p_print_location text,p_sequence_no integer,p_notes text,p_request_id uuid
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_job public.production_jobs%rowtype;
  v_actor uuid;
  v_payload jsonb;
  v_cached jsonb;
  v_id uuid;
  v_result jsonb;
begin
  select * into v_job from public.production_jobs where id=p_job_id;
  if not found then raise exception using errcode='P0002',message='Production job not found'; end if;
  v_actor:=private.assert_active_owner(v_job.business_id);
  if p_request_id is null
    or length(btrim(coalesce(p_colour_name,''))) not between 1 and 100
    or length(coalesce(p_ink_reference,''))>100
    or length(coalesce(p_screen_reference,''))>100
    or p_print_location not in ('front','back','left_sleeve','right_sleeve','cap_front','mug_wrap','other')
    or p_sequence_no is null or p_sequence_no<1
    or length(coalesce(p_notes,''))>1000 then
    raise exception using errcode='22023',message='Enter a valid colour separation, print location and sequence';
  end if;
  if v_job.status in ('completed','cancelled') then
    raise exception using errcode='55000',message='A completed or cancelled job cannot receive a new colour separation';
  end if;
  if p_artwork_id is not null and not exists(
    select 1 from public.sales_job_artworks a
    where a.business_id=v_job.business_id and a.job_id=p_job_id and a.id=p_artwork_id
  ) then
    raise exception using errcode='22023',message='Artwork version does not belong to this production job';
  end if;
  v_payload:=jsonb_build_object('job_id',p_job_id,'artwork_id',p_artwork_id,'colour_name',btrim(p_colour_name),
    'ink_reference',nullif(btrim(p_ink_reference),''),'screen_reference',nullif(btrim(p_screen_reference),''),
    'print_location',p_print_location,'sequence_no',p_sequence_no,'notes',nullif(btrim(p_notes),''));
  v_cached:=private.begin_idempotent_request(v_job.business_id,'add_job_colour_separation',p_request_id,v_payload);
  if v_cached is not null then return v_cached; end if;
  insert into public.sales_job_colour_separations(
    business_id,job_id,artwork_id,colour_name,ink_reference,screen_reference,print_location,sequence_no,notes
  ) values (
    v_job.business_id,p_job_id,p_artwork_id,btrim(p_colour_name),nullif(btrim(p_ink_reference),''),
    nullif(btrim(p_screen_reference),''),p_print_location,p_sequence_no,nullif(btrim(p_notes),'')
  ) returning id into v_id;
  v_result:=jsonb_build_object('colour_separation_id',v_id,'job_id',p_job_id);
  perform private.finish_idempotent_request(v_job.business_id,'add_job_colour_separation',p_request_id,v_result);
  perform private.write_audit(v_job.business_id,v_actor,'custom_order.colour_separation_added','sales_job_colour_separation',v_id,p_request_id,v_result);
  return v_result;
end;
$$;

create or replace function public.owner_add_job_size_breakdown(
  p_job_id uuid,p_person_name text,p_jersey_number text,p_size text,p_colour text,p_quantity numeric,p_notes text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_add_job_size_breakdown($1,$2,$3,$4,$5,$6,$7,$8); $$;

create or replace function public.owner_add_job_artwork(
  p_job_id uuid,p_storage_path text,p_file_name text,p_notes text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_add_job_artwork($1,$2,$3,$4,$5); $$;

create or replace function public.owner_set_job_artwork_status(
  p_artwork_id uuid,p_proof_status text,p_approved_by_contact_id uuid,p_notes text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_set_job_artwork_status($1,$2,$3,$4,$5); $$;

create or replace function public.owner_add_job_colour_separation(
  p_job_id uuid,p_artwork_id uuid,p_colour_name text,p_ink_reference text,p_screen_reference text,
  p_print_location text,p_sequence_no integer,p_notes text,p_request_id uuid
) returns jsonb language sql security invoker set search_path=''
as $$ select private.owner_add_job_colour_separation($1,$2,$3,$4,$5,$6,$7,$8,$9); $$;

revoke all on function private.owner_add_job_size_breakdown(uuid,text,text,text,text,numeric,text,uuid) from public,anon,authenticated;
revoke all on function private.owner_add_job_artwork(uuid,text,text,text,uuid) from public,anon,authenticated;
revoke all on function private.owner_set_job_artwork_status(uuid,text,uuid,text,uuid) from public,anon,authenticated;
revoke all on function private.owner_add_job_colour_separation(uuid,uuid,text,text,text,text,integer,text,uuid) from public,anon,authenticated;
grant execute on function private.owner_add_job_size_breakdown(uuid,text,text,text,text,numeric,text,uuid) to authenticated;
grant execute on function private.owner_add_job_artwork(uuid,text,text,text,uuid) to authenticated;
grant execute on function private.owner_set_job_artwork_status(uuid,text,uuid,text,uuid) to authenticated;
grant execute on function private.owner_add_job_colour_separation(uuid,uuid,text,text,text,text,integer,text,uuid) to authenticated;

revoke all on function public.owner_add_job_size_breakdown(uuid,text,text,text,text,numeric,text,uuid) from public,anon;
revoke all on function public.owner_add_job_artwork(uuid,text,text,text,uuid) from public,anon;
revoke all on function public.owner_set_job_artwork_status(uuid,text,uuid,text,uuid) from public,anon;
revoke all on function public.owner_add_job_colour_separation(uuid,uuid,text,text,text,text,integer,text,uuid) from public,anon;
grant execute on function public.owner_add_job_size_breakdown(uuid,text,text,text,text,numeric,text,uuid) to authenticated;
grant execute on function public.owner_add_job_artwork(uuid,text,text,text,uuid) to authenticated;
grant execute on function public.owner_set_job_artwork_status(uuid,text,uuid,text,uuid) to authenticated;
grant execute on function public.owner_add_job_colour_separation(uuid,uuid,text,text,text,text,integer,text,uuid) to authenticated;

commit;
