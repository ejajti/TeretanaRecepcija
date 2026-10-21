-- D-103 (BR-145, P-45): Poravnanje stanja. E26 (five bags of whey short: stock, stock
-- value and profit fall by €140, the cash flow does not move), who may adjust and void,
-- the count that no longer matches (E_STOCK_CHANGED), the reasons, goods found, and the
-- checks that keep stock-ins and sales as they were.
select plan(51);

-- Fixtures --------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('93939393-0000-0000-0000-00000000a001', null),
  ('93939393-0000-0000-0000-00000000a002', null),
  ('93939393-0000-0000-0000-00000000a003', null),
  ('93939393-0000-0000-0000-00000000a004', null);
insert into gyms (id, name, timezone) values
  ('93939393-0000-0000-0000-00000000b001', 'pgTAP Poravnanje', 'Europe/Podgorica'),
  ('93939393-0000-0000-0000-00000000b002', 'pgTAP Druga teretana', 'Europe/Podgorica');
insert into gym_settings (gym_id) values
  ('93939393-0000-0000-0000-00000000b001'),
  ('93939393-0000-0000-0000-00000000b002');
insert into staff (id, gym_id, user_id, role, full_name, username, email) values
  ('93939393-0000-0000-0000-00000000c001', '93939393-0000-0000-0000-00000000b001',
   '93939393-0000-0000-0000-00000000a001', 'owner', 'pgTAP Vlasnik', 'pgtap.por.vlasnik', null),
  ('93939393-0000-0000-0000-00000000c002', '93939393-0000-0000-0000-00000000b001',
   '93939393-0000-0000-0000-00000000a002', 'manager', 'pgTAP Menadzer', 'pgtap.por.menadzer', null),
  ('93939393-0000-0000-0000-00000000c003', '93939393-0000-0000-0000-00000000b001',
   '93939393-0000-0000-0000-00000000a003', 'receptionist', 'pgTAP Ana', 'pgtap.por.ana', null),
  ('93939393-0000-0000-0000-00000000c004', '93939393-0000-0000-0000-00000000b001',
   '93939393-0000-0000-0000-00000000a004', 'admin', 'pgTAP Admin', null, 'admin.por@pgtap.invalid');

insert into expense_categories (gym_id, name, is_system)
values ('93939393-0000-0000-0000-00000000b001', 'pgTAP Roba za prodaju', true);

-- E26: whey bought at €28 and sold at €41.
insert into products (id, gym_id, name, current_purchase_price, sale_price, is_active) values
  ('93939393-0000-0000-0000-00000000e001', '93939393-0000-0000-0000-00000000b001', 'pgTAP Whey', 28, 41, true),
  ('93939393-0000-0000-0000-00000000e002', '93939393-0000-0000-0000-00000000b001', 'pgTAP Neaktivni', 1, 2, false),
  ('93939393-0000-0000-0000-00000000e003', '93939393-0000-0000-0000-00000000b002', 'pgTAP Tuđi', 1, 2, true);

-- Ana's open shift, for the sales.
insert into shifts (id, gym_id, staff_id) values
  ('93939393-0000-0000-0000-00000000f001', '93939393-0000-0000-0000-00000000b001',
   '93939393-0000-0000-0000-00000000c003');

create temporary table d as
  select gym_today('93939393-0000-0000-0000-00000000b001') as today;
-- The owner's numbers before and after the count, read as `authenticated`.
create temporary table snap (label text primary key, statement jsonb, summary jsonb,
                             chart jsonb);
create temporary view e26 as
  select b.statement as sb, a.statement as sa, b.summary as ub, a.summary as ua,
         b.chart as cb, a.chart as ca
  from snap b, snap a where b.label = 'before' and a.label = 'after';
grant select on d, e26 to authenticated;
grant all on snap to authenticated;

-- Helper: the message and detail an RPC raises.
create function pg_temp.error_detail(p_sql text) returns text language plpgsql as $$
declare v_detail text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_detail = pg_exception_detail;
  return sqlerrm || '|' || coalesce(v_detail, '');
end $$;

-- The owner receives 10 bags outside the till, then reads the day --------------------
set local request.jwt.claims = '{"sub": "93939393-0000-0000-0000-00000000a001"}';
set local role authenticated;
select stock_in('93939393-0000-0000-0000-00000000e001', 10, 28.00, false);
insert into snap
  select 'before', fin_statement(today, today)::jsonb, fin_summary(today, today)::jsonb,
         fin_chart(extract(year from today)::int, extract(month from today)::int)::jsonb
  from d;
reset role;

-- A receptionist never adjusts (P-45) --------------------------------------------------
set local request.jwt.claims = '{"sub": "93939393-0000-0000-0000-00000000a003"}';
set local role authenticated;
select throws_ok(
  $$select adjust_stock('93939393-0000-0000-0000-00000000e001', 5, 10, 'damaged')$$,
  'P0001', 'E_FORBIDDEN', 'P-45: a receptionist may not adjust the stock');
reset role;

-- The manager: what is refused ---------------------------------------------------------
set local request.jwt.claims = '{"sub": "93939393-0000-0000-0000-00000000a002"}';
set local role authenticated;
select throws_ok(
  $$select adjust_stock('93939393-0000-0000-0000-00000000e001', -1, 10, 'count')$$,
  'P0001', 'E_VALIDATION', 'BR-145: a count below zero is refused');
select throws_ok(
  $$select adjust_stock('93939393-0000-0000-0000-00000000e001', 10001, 10, 'count')$$,
  'P0001', 'E_VALIDATION', 'BR-145: a count above 10,000 is refused');
select throws_ok(
  $$select adjust_stock('93939393-0000-0000-0000-00000000e001', 5, 10, 'stolen')$$,
  'P0001', 'E_VALIDATION', 'BR-145: only the listed reasons are accepted');
select throws_ok(
  $$select adjust_stock('93939393-0000-0000-0000-00000000e001', 5, 10, 'other', '  ')$$,
  'P0001', 'E_VALIDATION', 'BR-145: Ostalo needs a note of at least 3 characters');
select throws_ok(
  format($$select adjust_stock('93939393-0000-0000-0000-00000000e001', 5, 10, 'other', %L)$$,
         repeat('a', 201)),
  'P0001', 'E_VALIDATION', 'BR-145: a note is at most 200 characters');
select throws_ok(
  $$select adjust_stock('93939393-0000-0000-0000-00000000e001', 10, 10, 'count')$$,
  'P0001', 'E_VALIDATION', 'BR-145: a count equal to the stock level adjusts nothing');
select throws_ok(
  $$select adjust_stock('93939393-0000-0000-0000-00000000e001', 12, 10, 'damaged')$$,
  'P0001', 'E_VALIDATION', 'BR-145: goods found cannot be "Oštećeno"');
select is(
  pg_temp.error_detail(
    $$select adjust_stock('93939393-0000-0000-0000-00000000e001', 5, 9, 'damaged')$$),
  'E_STOCK_CHANGED|10',
  'BR-145: a count made against another stock level is refused and names the stock now');
select throws_ok(
  $$select adjust_stock('93939393-0000-0000-0000-00000000e002', 0, 0, 'count')$$,
  'P0001', 'E_VALIDATION', 'BR-145: an inactive product is not adjusted');
select throws_ok(
  $$select adjust_stock('93939393-0000-0000-0000-00000000e003', 0, 0, 'count')$$,
  'P0001', 'E_VALIDATION', 'Tenancy: another gym''s product is not adjusted');
select is((select count(*)::int from stock_movements where type = 'adjust'
           and gym_id = '93939393-0000-0000-0000-00000000b001'), 0,
  'Nothing refused was written');

-- E26: five bags short ------------------------------------------------------------------
select is(
  (select quantity from adjust_stock('93939393-0000-0000-0000-00000000e001', 5, 10,
                                     'damaged', '  Pukle kesice  ')),
  -5, 'E26: counting 5 of 10 writes a difference of -5');
select is(
  (select row(type::text, counted_qty, unit_cost, shift_id is null, paid_from_till,
              adjust_reason, note, created_by)::text
   from stock_movements
   where product_id = '93939393-0000-0000-0000-00000000e001' and type = 'adjust'),
  row('adjust', 5, 28.00, true, false, 'damaged', 'Pukle kesice',
      '93939393-0000-0000-0000-00000000c002'::uuid)::text,
  'BR-145: the count, the purchase price of the moment, the reason and the trimmed note; no shift');
select is((select stock from storage_products() where name = 'pgTAP Whey'), 5,
  'BR-143: the stock level is the count');
select throws_ok(
  $$select void_stock_movement((select id from stock_movements where type = 'adjust'
                                and product_id = '93939393-0000-0000-0000-00000000e001'),
                               'Pogrešno prebrojano')$$,
  'P0001', 'E_FORBIDDEN', 'BR-095: only the owner and the admin void an adjustment');
select is((select fin_summary(today, today)::jsonb from d),
  jsonb_build_object('income', '0.00', 'expenses', '280.00'),
  'D-80 and BR-157: a manager''s day is what was paid; the shortage is not shown');
reset role;
select is((select count(*)::int from expenses
           where gym_id = '93939393-0000-0000-0000-00000000b001'), 1,
  'BR-145: an adjustment writes no expense (only the stock-in''s)');

-- E26: the owner's day after the count ---------------------------------------------------
set local request.jwt.claims = '{"sub": "93939393-0000-0000-0000-00000000a001"}';
set local role authenticated;
insert into snap
  select 'after', fin_statement(today, today)::jsonb, fin_summary(today, today)::jsonb,
         fin_chart(extract(year from today)::int, extract(month from today)::int)::jsonb
  from d;

select is((select (sa ->> 'shrinkage')::numeric from e26), 140.00,
  'E26: Manjak robe is 5 × €28');
select is((select (sb ->> 'shrinkage')::numeric from e26), 0.00,
  'E26: no Manjak robe before the count');
select is((select (sb ->> 'gross_profit')::numeric - (sa ->> 'gross_profit')::numeric from e26),
  140.00, 'BR-152: gross profit falls by the shortage');
select is((select (sb ->> 'profit')::numeric - (sa ->> 'profit')::numeric from e26), 140.00,
  'E26: profit falls by €140');
select is((select sa -> 'cash_flow' from e26), (select sb -> 'cash_flow' from e26),
  'E26 and BR-158: the cash flow does not move');
select is((select (sa ->> 'stock_value')::numeric from e26), 140.00,
  'E26 and BR-159: the stock value is 5 × €28');
select is((select (sb ->> 'stock_value')::numeric - (sa ->> 'stock_value')::numeric from e26),
  140.00, 'E26: the stock value falls by €140');
select is((select (ua ->> 'expenses')::numeric - (ub ->> 'expenses')::numeric from e26),
  140.00, 'S-16: the owner''s Troškovi card includes Manjak robe');
select is((select ua ->> 'profit' from e26), (select sa ->> 'profit' from e26),
  'S-16: the Profit card is the statement''s profit');
select is((select ua ->> 'bar_profit' from e26), (select ub ->> 'bar_profit' from e26),
  'BR-153: bar profit stays the margin on sales');
select is((select (cb ->> 'profit')::numeric - (ca ->> 'profit')::numeric from e26), 140.00,
  'D-68: the chart''s profit falls with the statement''s');

select is(
  (select jsonb_build_object('adjust_quantity', p -> 'adjust_quantity',
                             'shrinkage', p -> 'shrinkage', 'stock', p -> 'stock',
                             'stock_value', p -> 'stock_value')
   from d, jsonb_array_elements(fin_storage(today, today)::jsonb -> 'products') p
   where p ->> 'name' = 'pgTAP Whey'),
  jsonb_build_object('adjust_quantity', -5, 'shrinkage', '140.00', 'stock', 5,
                     'stock_value', '140.00'),
  'S-20: the product row shows the adjustment and the stock after it');
select is(
  (select jsonb_build_object('name', a -> 'name', 'before_qty', a -> 'before_qty',
                             'counted_qty', a -> 'counted_qty', 'quantity', a -> 'quantity',
                             'adjust_reason', a -> 'adjust_reason', 'note', a -> 'note',
                             'shrinkage', a -> 'shrinkage',
                             'created_by_name', a -> 'created_by_name')
   from d, jsonb_array_elements(fin_storage(today, today)::jsonb -> 'adjustments') a),
  jsonb_build_object('name', 'pgTAP Whey', 'before_qty', 10, 'counted_qty', 5,
                     'quantity', -5, 'adjust_reason', 'damaged', 'note', 'Pukle kesice',
                     'shrinkage', '140.00', 'created_by_name', 'pgTAP Menadzer'),
  'S-20: the adjustment is listed with the stock before, the count and who entered it');
reset role;
select is(
  (select count(*)::int from audit_log
   where table_name = 'stock_movements' and action = 'insert'
     and row_id = (select id::text from stock_movements where type = 'adjust'
                   and product_id = '93939393-0000-0000-0000-00000000e001')),
  1, 'BR-096: the adjustment is in Dnevnik izmjena');

-- The desk sells from the counted stock ---------------------------------------------------
set local request.jwt.claims = '{"sub": "93939393-0000-0000-0000-00000000a003"}';
set local role authenticated;
select is(
  pg_temp.error_detail(
    $$select stock_sale('93939393-0000-0000-0000-00000000e001', 6, 'cash')$$),
  'E_STOCK_INSUFFICIENT|5', 'D-34: a sale cannot exceed the counted stock');
select stock_sale('93939393-0000-0000-0000-00000000e001', 1, 'cash');
select is((select stock from storage_products() where name = 'pgTAP Whey'), 4,
  'BR-143: a sale after the count takes from it');
reset role;

-- Goods found -----------------------------------------------------------------------------
set local request.jwt.claims = '{"sub": "93939393-0000-0000-0000-00000000a002"}';
set local role authenticated;
select is(
  (select quantity from adjust_stock('93939393-0000-0000-0000-00000000e001', 6, 4,
                                     'other', 'Nađeno u ormaru')),
  2, 'BR-145: goods found are a positive difference (Ostalo with its note)');
reset role;

set local request.jwt.claims = '{"sub": "93939393-0000-0000-0000-00000000a003"}';
set local role authenticated;
select stock_sale('93939393-0000-0000-0000-00000000e001', 5, 'card');
reset role;

-- The owner voids -------------------------------------------------------------------------
set local request.jwt.claims = '{"sub": "93939393-0000-0000-0000-00000000a001"}';
set local role authenticated;
select throws_ok(
  $$select void_stock_movement((select id from stock_movements where type = 'adjust'
                                and quantity = 2
                                and product_id = '93939393-0000-0000-0000-00000000e001'),
                               'Nije bilo viška')$$,
  'P0001', 'E_STOCK_NEGATIVE',
  'BR-095: goods found cannot be voided once they are sold');
select is(
  (select quantity from void_stock_movement(
     (select id from stock_movements where type = 'adjust' and quantity = -5
      and product_id = '93939393-0000-0000-0000-00000000e001'),
     'Pogrešno prebrojano')),
  -5, 'BR-095: the owner voids the shortage');
select is((select stock from storage_products() where name = 'pgTAP Whey'), 6,
  'BR-095: voiding the shortage puts the five bags back');
select is(
  (select quantity from void_stock_movement(
     (select id from stock_movements where type = 'adjust' and quantity = 2
      and product_id = '93939393-0000-0000-0000-00000000e001'),
     'Nije bilo viška')),
  2, 'BR-095: with stock enough, goods found can be voided');
select is((select stock from storage_products() where name = 'pgTAP Whey'), 4,
  'BR-143: voided adjustments no longer count');
select throws_ok(
  $$select void_stock_movement((select id from stock_movements where type = 'adjust'
                                and quantity = 2
                                and product_id = '93939393-0000-0000-0000-00000000e001'),
                               'Ponovo')$$,
  'P0001', 'E_RECORD_NOT_EDITABLE', 'BR-095: a voided adjustment is not voided twice');
select is((select (fin_statement(today, today)::jsonb ->> 'shrinkage')::numeric from d), 0.00,
  'BR-095: voided adjustments are not in Manjak robe');
select is(
  (select count(*)::int
   from d, jsonb_array_elements(fin_storage(today, today)::jsonb -> 'adjustments') a
   where a ->> 'voided_at' is not null and a ->> 'void_reason' is not null),
  2, 'BR-095: voided adjustments stay listed with their reasons');
reset role;

-- The admin adjusts too (P-45, D-58) ---------------------------------------------------------
set local request.jwt.claims = '{"sub": "93939393-0000-0000-0000-00000000a004"}';
set local role authenticated;
select is(
  (select quantity from adjust_stock('93939393-0000-0000-0000-00000000e001', 3, 4, 'expired')),
  -1, 'P-45: the admin adjusts the stock');
reset role;

-- Privileges: signed-in staff only; the internal stock functions stay internal ---------------
select ok(has_function_privilege('authenticated',
            'adjust_stock(uuid, integer, integer, text, text)', 'execute')
          and not has_function_privilege('anon',
            'adjust_stock(uuid, integer, integer, text, text)', 'execute'),
  'adjust_stock: authenticated may call it (the role is checked inside), anon may not');
select ok(not has_function_privilege('authenticated', 'product_stock(uuid)', 'execute')
          and not has_function_privilege('authenticated', 'product_stock_at(uuid, date)', 'execute'),
  'product_stock and product_stock_at stay callable by other functions only');

-- The table's checks: stock-ins and sales are what they were ---------------------------------
select throws_ok(
  $$insert into stock_movements (gym_id, product_id, type, quantity, unit_cost, unit_price,
                                 method, created_by)
    values ('93939393-0000-0000-0000-00000000b001', '93939393-0000-0000-0000-00000000e001',
            'out', 1, 28, 41, 'cash', '93939393-0000-0000-0000-00000000c003')$$,
  '23514', null, 'A sale still needs its shift');
select throws_ok(
  $$insert into stock_movements (gym_id, product_id, type, quantity, unit_cost,
                                 counted_qty, adjust_reason, created_by)
    values ('93939393-0000-0000-0000-00000000b001', '93939393-0000-0000-0000-00000000e001',
            'adjust', 0, 28, 3, 'count', '93939393-0000-0000-0000-00000000c002')$$,
  '23514', null, 'An adjustment is never zero');
select throws_ok(
  $$insert into stock_movements (gym_id, product_id, type, quantity, unit_cost,
                                 counted_qty, adjust_reason, created_by, shift_id)
    values ('93939393-0000-0000-0000-00000000b001', '93939393-0000-0000-0000-00000000e001',
            'adjust', -1, 28, 2, 'count', '93939393-0000-0000-0000-00000000c002',
            '93939393-0000-0000-0000-00000000f001')$$,
  '23514', null, 'BR-092: an adjustment is not money and has no shift');
select throws_ok(
  $$insert into stock_movements (gym_id, product_id, type, quantity, unit_cost,
                                 counted_qty, created_by)
    values ('93939393-0000-0000-0000-00000000b001', '93939393-0000-0000-0000-00000000e001',
            'in', 1, 28, 1, '93939393-0000-0000-0000-00000000c001')$$,
  '23514', null, 'A stock-in carries no count');
select throws_ok(
  $$insert into stock_movements (gym_id, product_id, type, quantity, unit_cost, created_by)
    values ('93939393-0000-0000-0000-00000000b001', '93939393-0000-0000-0000-00000000e001',
            'in', -1, 28, '93939393-0000-0000-0000-00000000c001')$$,
  '23514', null, 'A stock-in is still at least one unit');

select * from finish();
