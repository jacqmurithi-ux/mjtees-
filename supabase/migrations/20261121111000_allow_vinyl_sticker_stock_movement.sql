alter table public.stock_movements
  drop constraint if exists stock_movements_movement_type_check;

alter table public.stock_movements
  add constraint stock_movements_movement_type_check
  check (movement_type = any (array[
    'opening','purchase','job_issue','transfer_in','transfer_out',
    'adjustment','offcut_return','vinyl_sticker_sale'
  ]));