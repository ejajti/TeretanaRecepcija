-- D-104 (BR-133, BR-151, BR-156, BR-158): Trošak za mjesec. E27 (last month's electricity
-- paid today is last month's cost and this month's payment), the months that may be
-- chosen, every role choosing it, the payout that counts for the month it is for, a
-- manager's finance as paid, and an expense without a month reading as before.
select plan(37);

-- Fixtures --------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('94949494-0000-0000-0000-00000000a001', null),
  ('94949494-0000-0000-0000-00000000a002', null),
  ('94949494-0000-0000-0000-00000000a003', null);
insert into gyms (id, name, timezone)
values ('94949494-0000-0000-0000-00000000b001', 'pgTAP Mjesec troška', 'Europe/Podgorica');
insert into gym_settings (gym_id) values ('94949494-0000-0000-0000-00000000b001');
insert into staff (id, gym_id, user_id, role, full_name, username) values
  ('94949494-0000-0000-0000-00000000c001', '94949494-0000-0000-0000-00000000b001',
   '94949494-0000-0000-0000-00000000a001', 'owner', 'pgTAP Vlasnik', 'pgtap.mjt.vlasnik'),
  ('94949494-0000-0000-0000-00000000c002', '94949494-0000-0000-0000-00000000b001',
   '94949494-0000-0000-0000-00000000a002', 'manager', 'pgTAP Menadzer', 'pgtap.mjt.menadzer'),
  ('94949494-0000-0000-0000-00000000c003', '94949494-0000-0000-0000-00000000b001',
   '94949494-0000-0000-0000-00000000a003', 'receptionist', 'pgTAP Ana', 'pgtap.mjt.ana');
insert into expense_categories (id, gym_id, name, is_salary, is_system) values
  ('94949494-0000-0000-0000-000000060001', '94949494-0000-0000-0000-00000000b001', 'pgTAP Struja', false, false),
  ('94949494-0000-0000-0000-000000060002', '94949494-0000-0000-0000-00000000b001', 'pgTAP Plate', true, false),
  ('94949494-0000-0000-0000-000000060003', '94949494-0000-0000-0000-00000000b001', 'pgTAP Roba za prodaju', false, true);
insert into trainers (id, gym_id, full_name) values
  ('94949494-0000-0000-0000-00000000d001', '94949494-0000-0000-0000-00000000b001', 'pgTAP Tamara');
insert into products (id, gym_id, name, current_purchase_price, sale_price) values
  ('94949494-0000-0000-0000-00000000e001', '94949494-0000-0000-0000-00000000b001', 'pgTAP Voda', 0.30, 1.50);
insert into shifts (id, gym_id, staff_id) values
  ('94949494-0000-0000-0000-00000000f001', '94949494-0000-0000-0000-00000000b001',
   '94949494-0000-0000-0000-00000000c003');

-- The gym's today and the months around it.
create temporary table d as
  select t.today,
         date_trunc('month', t.today::timestamp)::date as this_month,
         (date_trunc('month', t.today::timestamp) + interval '1 month - 1 day')::date as month_end,
         (date_trunc('month', t.today::timestamp) - interval '1 month')::date as last_month,
         (date_trunc('month', t.today::timestamp) - interval '1 day')::date as last_month_end,
         (date_trunc('month', t.today::timestamp) - interval '12 months')::date as year_back,
         (date_trunc('month', t.today::timestamp) - interval '11 months'
          - interval '1 day')::date as year_back_end
  from (select gym_today('94949494-0000-0000-0000-00000000b001') as today) t;
grant select on d to authenticated;

-- The owner records the month's bills ------------------------------------------------
set local request.jwt.claims = '{"sub": "94949494-0000-0000-0000-00000000a001"}';
set local role authenticated;

-- E27: last month's electricity, paid today by card.
select is(
  (select cost_month from d, record_expense(
     p_category := '94949494-0000-0000-0000-000000060001', p_description := 'Struja prošli mjesec',
     p_amount := 120, p_spent_on := d.today, p_method := 'card', p_cost_month := d.last_month)),
  (select last_month from d),
  'E27: an expense paid today names the month it is for');
select is(
  (select cost_month from d, record_expense(
     p_category := '94949494-0000-0000-0000-000000060001', p_description := 'Struja ovaj mjesec',
     p_amount := 30, p_spent_on := d.today, p_method := 'card', p_cost_month := d.this_month)),
  null::date, 'D-104: the month it was paid is stored as no month of its own');
select is(
  (select cost_month from d, record_expense(
     p_category := '94949494-0000-0000-0000-000000060001', p_description := 'Struja od prije godinu',
     p_amount := 10, p_spent_on := d.today, p_method := 'card', p_cost_month := d.year_back)),
  (select year_back from d), 'BR-133: twelve months before the month paid may be chosen');
select is(
  (select cost_month from d, record_expense(
     p_category := '94949494-0000-0000-0000-000000060002', p_description := 'Plata Tamara',
     p_amount := 200, p_spent_on := d.today,
     p_trainer := '94949494-0000-0000-0000-00000000d001', p_cost_month := d.last_month)),
  (select last_month from d), 'BR-156: a payout may be for last month');
-- A form from before D-104 sends no month: it is the month paid, as before.
select is(
  (select cost_month from d, record_expense(
     p_category := '94949494-0000-0000-0000-000000060001', p_description := 'Bez mjeseca',
     p_amount := 7, p_spent_on := d.today, p_method := 'cash')),
  null::date, 'D-104: a call without the month records the month paid');

select throws_ok(
  $$select record_expense(p_category := '94949494-0000-0000-0000-000000060001',
                          p_description := 'Struja', p_amount := 1,
                          p_spent_on := (select today from d), p_method := 'card',
                          p_cost_month := (select last_month + 4 from d))$$,
  'P0001', 'E_VALIDATION', 'BR-133: the month is the 1st of a month');
select throws_ok(
  $$select record_expense(p_category := '94949494-0000-0000-0000-000000060001',
                          p_description := 'Struja', p_amount := 1,
                          p_spent_on := (select today from d), p_method := 'card',
                          p_cost_month := (select month_end + 1 from d))$$,
  'P0001', 'E_VALIDATION', 'BR-133: a month after the month paid is refused');
select throws_ok(
  $$select record_expense(p_category := '94949494-0000-0000-0000-000000060001',
                          p_description := 'Struja', p_amount := 1,
                          p_spent_on := (select today from d), p_method := 'card',
                          p_cost_month := (select (year_back - interval '1 month')::date from d))$$,
  'P0001', 'E_VALIDATION', 'BR-133: thirteen months back is refused');
select throws_ok(
  $$select record_expense(p_category := '94949494-0000-0000-0000-000000060001',
                          p_description := 'Struja', p_amount := 1,
                          p_spent_on := (select last_month_end from d), p_method := 'card',
                          p_cost_month := (select this_month from d))$$,
  'P0001', 'E_VALIDATION', 'BR-133: the window follows the day paid, not today');
select stock_in('94949494-0000-0000-0000-00000000e001', 10, 0.30, false);
reset role;

-- Every role chooses the month; from the till it is still today's cash ---------------------
set local request.jwt.claims = '{"sub": "94949494-0000-0000-0000-00000000a003"}';
set local role authenticated;
select is(
  (select row(cost_month = d.last_month, spent_on = d.today, paid_from_till, shift_id)::text
   from d, record_expense(
     p_category := '94949494-0000-0000-0000-000000060001', p_description := 'Struja iz kase',
     p_amount := 5, p_spent_on := d.last_month, p_from_till := true,
     p_cost_month := d.last_month)),
  row(true, true, true, '94949494-0000-0000-0000-00000000f001'::uuid)::text,
  'D-104: the desk pays last month''s bill from the till today, on the open shift');
reset role;

-- E27 for the owner ---------------------------------------------------------------------
set local request.jwt.claims = '{"sub": "94949494-0000-0000-0000-00000000a001"}';
set local role authenticated;
create temporary table st as
  select (select fin_statement(last_month, last_month_end)::jsonb from d) as last_m,
         (select fin_statement(this_month, today)::jsonb from d) as this_m,
         (select fin_statement(year_back, year_back_end)::jsonb from d) as year_m,
         (select fin_summary(last_month, last_month_end)::jsonb from d) as sum_last,
         (select fin_summary(this_month, today)::jsonb from d) as sum_this;

select is((select (last_m ->> 'operating_total')::numeric from st), 325.00,
  'E27 and BR-151: last month''s operating expenses are what is for it (120 + 5 + 200)');
select is((select (last_m -> 'cash_flow' ->> 'other_paid')::numeric from st), 0.00,
  'E27 and BR-158: last month paid none of it');
select is((select (last_m ->> 'profit')::numeric from st), -325.00,
  'BR-152: last month''s profit carries its bills');
select is(
  (select t ->> 'total' from st, jsonb_array_elements(last_m -> 'operating') t
   where t ->> 'name' = 'pgTAP Struja'),
  '125.00', 'S-16: last month''s Struja is 120 + 5');
select is((select (this_m ->> 'operating_total')::numeric from st), 37.00,
  'E27: this month''s operating expenses leave out what is for other months (30 + 7)');
select is((select (this_m -> 'cash_flow' ->> 'other_paid')::numeric from st), 372.00,
  'E27 and BR-158: this month paid all of it (120 + 30 + 10 + 200 + 7 + 5)');
select is((select (this_m -> 'cash_flow' ->> 'goods_paid')::numeric from st), 3.00,
  'BR-158: goods bought stay on the day paid');
select is((select (this_m -> 'cash_flow' ->> 'net_change')::numeric from st), -375.00,
  'BR-158: the net change is what this month paid');
select is((select (year_m ->> 'operating_total')::numeric from st), 10.00,
  'BR-151: the bill of a year ago is in that month');
select is((select (sum_last ->> 'expenses')::numeric from st), 325.00,
  'S-16: the owner''s Troškovi card for last month includes its bills');
select is((select sum_last ->> 'profit' from st), (select last_m ->> 'profit' from st),
  'S-16: the Profit card is the statement''s');
select is((select (sum_this ->> 'expenses')::numeric from st), 37.00,
  'S-16: this month''s Troškovi card leaves them out');

select is(
  (select (fin_chart(extract(year from last_month)::int,
                     extract(month from last_month)::int)::jsonb ->> 'expenses')::numeric
   from d),
  325.00, 'D-68: last month''s chart carries its bills');
select is(
  (select p ->> 'expenses'
   from d, jsonb_array_elements(fin_chart(extract(year from last_month)::int,
                                          extract(month from last_month)::int)::jsonb
                                -> 'points') p
   where p ->> 'date' = to_char(d.last_month, 'YYYY-MM-DD')),
  '325.00', 'D-104: on the chart a bill for a month sits on its 1st');
select is(
  (select (fin_chart(extract(year from this_month)::int,
                     extract(month from this_month)::int)::jsonb ->> 'expenses')::numeric
   from d),
  37.00, 'D-68: this month''s chart leaves them out');

select is(
  (select t ->> 'paid_out' from d, jsonb_array_elements(fin_trainer_stats(last_month)::jsonb) t
   where t ->> 'trainer_name' = 'pgTAP Tamara'),
  '200.00', 'BR-156: last month''s salary paid today is last month''s Isplaćeno');
select is(
  (select t ->> 'paid_out' from d, jsonb_array_elements(fin_trainer_stats(this_month)::jsonb) t
   where t ->> 'trainer_name' = 'pgTAP Tamara'),
  '0', 'BR-156: and not this month''s');

select is(
  (select e ->> 'cost_month' from d, jsonb_array_elements(fin_expenses(this_month, today)::jsonb) e
   where e ->> 'description' = 'Struja prošli mjesec'),
  (select to_char(last_month, 'YYYY-MM-DD') from d),
  'S-17: the list shows the bill on the day it was paid, with its month');
select is(
  (select count(*)::int from d, jsonb_array_elements(fin_expenses(this_month, today)::jsonb) e),
  7, 'S-17: the list is by the day paid (six expenses and the stock-in)');
select is(
  (select t ->> 'total' from d,
     jsonb_array_elements(fin_income_breakdown(this_month, today)::jsonb -> 'by_category') t
   where t ->> 'name' = 'pgTAP Struja'),
  '172.00', 'D-80: expenses by category stay what was paid (120 + 30 + 10 + 7 + 5)');
reset role;

-- A manager's finance is what was paid (D-80) ------------------------------------------------
set local request.jwt.claims = '{"sub": "94949494-0000-0000-0000-00000000a002"}';
set local role authenticated;
select is(
  (select fin_summary(this_month, month_end)::jsonb ->> 'expenses' from d),
  '175.00', 'D-80: a manager''s Troškovi are this month''s payments without salaries');
select is(
  (select cost_month from d, record_expense(
     p_category := '94949494-0000-0000-0000-000000060001', p_description := 'Menadžer struja',
     p_amount := 1, p_spent_on := d.today, p_method := 'cash', p_cost_month := d.last_month)),
  (select last_month from d), 'D-104: a manager chooses the month too');
reset role;

-- The table and the log -------------------------------------------------------------------------
select is(
  (select new_data ->> 'cost_month' from audit_log
   where table_name = 'expenses' and action = 'insert'
     and new_data ->> 'description' = 'Struja prošli mjesec'),
  (select to_char(last_month, 'YYYY-MM-DD') from d), 'BR-096: the month is in Dnevnik izmjena');
select throws_ok(
  $$update expenses set cost_month = (select this_month from d)
    where description = 'Bez mjeseca'
      and gym_id = '94949494-0000-0000-0000-00000000b001'$$,
  '23514', null, 'The month paid is never stored as a month of its own');
select throws_ok(
  $$update expenses set cost_month = (select last_month from d)
    where stock_movement_id is not null
      and gym_id = '94949494-0000-0000-0000-00000000b001'$$,
  '23514', null, 'D-92: goods bought have no month of their own');
select throws_ok(
  $$update expenses set cost_month = (select (year_back - interval '1 month')::date from d)
    where description = 'Bez mjeseca'
      and gym_id = '94949494-0000-0000-0000-00000000b001'$$,
  '23514', null, 'The table refuses a month more than 12 before the month paid');
select ok(
  not exists (select 1 from pg_proc where proname = 'record_expense' and pronargs = 10)
  and has_function_privilege('authenticated',
        'record_expense(uuid, text, numeric, date, payment_method, boolean, text, text, boolean, uuid, date)',
        'execute')
  and not has_function_privilege('anon',
        'record_expense(uuid, text, numeric, date, payment_method, boolean, text, text, boolean, uuid, date)',
        'execute'),
  'record_expense: one version, for signed-in staff only');

select * from finish();
