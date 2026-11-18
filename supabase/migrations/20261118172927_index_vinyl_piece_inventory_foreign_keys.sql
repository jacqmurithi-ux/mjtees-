-- MJ Tees — indexes for vinyl piece inventory foreign keys
-- Version: 20261118172927
-- Applied to live after the initial schema migration.

create index vinyl_cutting_settings_method_idx
  on public.vinyl_cutting_settings(production_method_id);
create index vinyl_cutting_settings_approved_by_idx
  on public.vinyl_cutting_settings(approved_by) where approved_by is not null;
create index vinyl_cutting_settings_created_by_idx
  on public.vinyl_cutting_settings(created_by);
create index vinyl_cut_operations_method_idx
  on public.vinyl_cut_operations(production_method_id);
create index vinyl_cut_operations_operator_idx
  on public.vinyl_cut_operations(operator_user_id);
create index vinyl_material_pieces_location_idx
  on public.vinyl_material_pieces(business_id, location_id);
create index vinyl_material_pieces_source_issue_idx
  on public.vinyl_material_pieces(business_id, source_issue_id)
  where source_issue_id is not null;
create index vinyl_material_pieces_source_operation_idx
  on public.vinyl_material_pieces(business_id, source_cut_operation_id)
  where source_cut_operation_id is not null;
create index vinyl_material_pieces_created_by_idx
  on public.vinyl_material_pieces(created_by);
create index vinyl_cut_inputs_piece_idx
  on public.vinyl_cut_inputs(business_id, piece_id);
create index vinyl_cut_results_piece_idx
  on public.vinyl_cut_results(business_id, piece_id)
  where piece_id is not null;
create index vinyl_piece_reservations_piece_idx
  on public.vinyl_piece_reservations(business_id, piece_id);
create unique index vinyl_piece_reservations_request_idx
  on public.vinyl_piece_reservations(business_id, request_id, piece_id);
create index vinyl_piece_reservations_operation_idx
  on public.vinyl_piece_reservations(business_id, operation_id)
  where operation_id is not null;
create index vinyl_piece_reservations_reserved_by_idx
  on public.vinyl_piece_reservations(reserved_by);
create index vinyl_piece_movements_related_piece_idx
  on public.vinyl_piece_movements(business_id, related_piece_id)
  where related_piece_id is not null;
create index vinyl_piece_movements_operation_idx
  on public.vinyl_piece_movements(business_id, operation_id)
  where operation_id is not null;
create index vinyl_piece_movements_reservation_idx
  on public.vinyl_piece_movements(business_id, reservation_id)
  where reservation_id is not null;
create index vinyl_piece_movements_from_location_idx
  on public.vinyl_piece_movements(business_id, from_location_id)
  where from_location_id is not null;
create index vinyl_piece_movements_to_location_idx
  on public.vinyl_piece_movements(business_id, to_location_id)
  where to_location_id is not null;
create index vinyl_piece_movements_actor_idx
  on public.vinyl_piece_movements(actor_user_id);
