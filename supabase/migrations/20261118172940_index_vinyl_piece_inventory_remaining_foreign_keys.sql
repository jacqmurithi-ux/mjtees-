-- MJ Tees — remaining vinyl piece inventory foreign-key indexes
-- Version: 20261118172940
-- Applied to live after the first index pass.

create index vinyl_cut_results_input_fk_idx
  on public.vinyl_cut_results(business_id, operation_id, input_id);
create index vinyl_piece_reservations_job_fk_idx
  on public.vinyl_piece_reservations(business_id, job_id);
