-- MJ Tees — enforce the approved maximum usable vinyl width
-- Version: 20261118173034
-- Maximum usable width is 58 cm (580,000 micrometres).
-- Physical metres may span any measured positive length; this constraint applies only to width.

alter table public.vinyl_material_pieces
  add constraint vinyl_material_pieces_max_usable_width
  check (width_um <= 580000);
