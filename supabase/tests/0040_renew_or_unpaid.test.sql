-- D-109 (migration 0062): a scan of a member whose membership has expired, or whose
-- sessions of the type are used up, records nothing and asks (S-03f). [Neplaćeni dolazak]
-- records the unpaid visit; [Produži članarinu] sells with p_check_in, which checks the
-- member in with the new membership in the same transaction, from the first unpaid visit
-- (BR-052 step 2). A Grupni-only member outside their class still gets an unpaid gym
-- visit at once (D-102).
select plan(22);

-- Fixtures --------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('61616161-0000-0000-0000-00000000a001', null),
  ('61616161-0000-0000-0000-00000000a002', null);
insert into gyms (id, name, timezone)
values ('61616161-0000-0000-0000-00000000b001', 'pgTAP Produzi ili neplaceno', 'Europe/Podgorica');
insert into gym_settings (gym_id) values ('61616161-0000-0000-0000-00000000b001');
insert into staff (id, gym_id, user_id, role, full_name, username) values
  ('61616161-0000-0000-0000-00000000c001', '61616161-0000-0000-0000-00000000b001',
   '61616161-0000-0000-0000-00000000a001', 'receptionist', 'pgTAP Recepcija', 'pgtap.pn.recepcija'),
  ('61616161-0000-0000-0000-00000000c002', '61616161-0000-0000-0000-00000000b001',
   '61616161-0000-0000-0000-00000000a002', 'owner', 'pgTAP Vlasnik', 'pgtap.pn.vlasnik');
insert into shifts (id, gym_id, staff_id)
values ('61616161-0000-0000-0000-00000000c101', '61616161-0000-0000-0000-00000000b001',
        '61616161-0000-0000-0000-00000000c001');

-- Milena and Alina run group classes, Tamara personal training (BR-023).
insert into trainers (id, gym_id, full_name) values
  ('61616161-0000-0000-0000-00000000d001', '61616161-0000-0000-0000-00000000b001', 'pgTAP Milena'),
  ('61616161-0000-0000-0000-00000000d002', '61616161-0000-0000-0000-00000000b001', 'pgTAP Tamara'),
  ('61616161-0000-0000-0000-00000000d004', '61616161-0000-0000-0000-00000000b001', 'pgTAP Alina');
insert into trainer_finance (trainer_id, gym_id)
select id, gym_id from trainers where gym_id = '61616161-0000-0000-0000-00000000b001';
insert into programs (id, gym_id, name, kind) values
  ('61616161-0000-0000-0000-00000000e001', '61616161-0000-0000-0000-00000000b001', 'pgTAP Grupni', 'group'),
  ('61616161-0000-0000-0000-00000000e002', '61616161-0000-0000-0000-00000000b001', 'pgTAP Personalni', 'personal');
insert into trainer_programs (gym_id, trainer_id, program_id) values
  ('61616161-0000-0000-0000-00000000b001', '61616161-0000-0000-0000-00000000d001', '61616161-0000-0000-0000-00000000e001'),
  ('61616161-0000-0000-0000-00000000b001', '61616161-0000-0000-0000-00000000d004', '61616161-0000-0000-0000-00000000e001'),
  ('61616161-0000-0000-0000-00000000b001', '61616161-0000-0000-0000-00000000d002', '61616161-0000-0000-0000-00000000e002');

-- Milena's classes (local time): e101 today now, e102 today in three hours. Alina's e104
-- is held only on tomorrow's weekday.
create temporary table clock as
select date_trunc('minute', now() at time zone 'Europe/Podgorica') as ts,
       extract(isodow from now() at time zone 'Europe/Podgorica')::smallint as today,
       (extract(isodow from now() at time zone 'Europe/Podgorica')::int % 7 + 1)::smallint as tomorrow,
       gym_today('61616161-0000-0000-0000-00000000b001') as d;
insert into class_slots (id, gym_id, program_id, trainer_id, weekday, starts_at)
select v.id::uuid, '61616161-0000-0000-0000-00000000b001', '61616161-0000-0000-0000-00000000e001',
       v.trainer::uuid, v.weekday, v.starts_at
from clock c, lateral (values
  ('61616161-0000-0000-0000-00000000e101', '61616161-0000-0000-0000-00000000d001', c.today, c.ts::time),
  ('61616161-0000-0000-0000-00000000e102', '61616161-0000-0000-0000-00000000d001', c.today, (c.ts + interval '3 hours')::time),
  ('61616161-0000-0000-0000-00000000e104', '61616161-0000-0000-0000-00000000d004', c.tomorrow, (c.ts + interval '1 minute')::time)
) as v(id, trainer, weekday, starts_at);

-- Plans: f001 Mjesečna, f002 Mjesečna 12 termina, f003 Grupni.
insert into plans (id, gym_id, name, kind, duration_value, duration_unit, price,
                   covers_gym, covers_group, covers_personal,
                   gym_visit_limit, group_session_limit, requires_trainer) values
  ('61616161-0000-0000-0000-00000000f001', '61616161-0000-0000-0000-00000000b001', 'pgTAP Mjesečna',
   'gym', 1, 'month', 79, true, false, false, null, null, false),
  ('61616161-0000-0000-0000-00000000f002', '61616161-0000-0000-0000-00000000b001', 'pgTAP Mjesečna 12',
   'gym', 1, 'month', 59, true, false, false, 12, null, false),
  ('61616161-0000-0000-0000-00000000f003', '61616161-0000-0000-0000-00000000b001', 'pgTAP Grupni',
   'group', 1, 'month', 69, false, true, false, null, 12, true);
insert into plan_finance (plan_id, gym_id)
select id, gym_id from plans where gym_id = '61616161-0000-0000-0000-00000000b001';

insert into members (id, gym_id, member_number, first_name, last_name, phone, email,
                     date_of_birth, created_by)
select ('61616161-0000-0000-0000-0000000200' || lpad(n::text, 2, '0'))::uuid,
       '61616161-0000-0000-0000-00000000b001', n, 'Član', 'Broj ' || n,
       '+3826761000' || lpad(n::text, 2, '0'), 'pn' || n || '@pgtap.invalid', '1990-01-01',
       '61616161-0000-0000-0000-00000000c002'
from generate_series(1, 9) as n;

-- Memberships: member, plan, trainer, fixed class time (by slot), start and end offsets,
-- coverage and limits. Member 2 has none.
insert into memberships (id, gym_id, member_id, plan_id, trainer_id, class_time, start_date,
                         end_date, start_reason, covers_gym, covers_group, covers_personal,
                         gym_visit_limit, group_session_limit, personal_session_limit,
                         is_backdated, created_by)
select v.id::uuid, '61616161-0000-0000-0000-00000000b001',
       ('61616161-0000-0000-0000-0000000200' || v.member)::uuid,
       ('61616161-0000-0000-0000-00000000' || v.plan)::uuid,
       ('61616161-0000-0000-0000-00000000' || v.trainer)::uuid,
       (select starts_at from class_slots where id = ('61616161-0000-0000-0000-00000000' || v.slot)::uuid),
       c.d + v.s, c.d + v.e, 'fixture', v.g, v.gr, false, v.gl, v.grl, null, true,
       '61616161-0000-0000-0000-00000000c002'
from clock c, (values
  -- 1, 6, 7: a Mjesečna that ended three days ago.
  ('61616161-0000-0000-0000-000000030001', '01', 'f001', null, null, -33, -3, true, false, null::smallint, null::smallint),
  ('61616161-0000-0000-0000-000000030006', '06', 'f001', null, null, -33, -3, true, false, null, null),
  ('61616161-0000-0000-0000-000000030007', '07', 'f001', null, null, -33, -3, true, false, null, null),
  -- 3: a valid Grupni with all twelve sessions used, class now.
  ('61616161-0000-0000-0000-000000030003', '03', 'f003', 'd001', 'e101', -15, 15, false, true, null, 12),
  -- 4: a valid Grupni whose class is in three hours.
  ('61616161-0000-0000-0000-000000030004', '04', 'f003', 'd001', 'e102', -15, 15, false, true, null, 12),
  -- 5: a valid Mjesečna 12 termina with all twelve used.
  ('61616161-0000-0000-0000-000000030005', '05', 'f002', null, null, -15, 15, true, false, 12, null),
  -- 8: a Grupni with Alina that ended three days ago.
  ('61616161-0000-0000-0000-000000030008', '08', 'f003', 'd004', 'e104', -33, -3, false, true, null, 12),
  -- 9: a Mjesečna that ended ten days ago.
  ('61616161-0000-0000-0000-000000030009', '09', 'f001', null, null, -40, -10, true, false, null, null)
) as v(id, member, plan, trainer, slot, s, e, g, gr, gl, grl);

-- Twelve used sessions for members 3 and 5; one unpaid gym visit two days ago for 9.
insert into visits (gym_id, member_id, membership_id, visit_type, trainer_id, checked_in_at,
                    checked_out_at, checked_in_by, is_backdated)
select '61616161-0000-0000-0000-00000000b001', ('61616161-0000-0000-0000-0000000200' || v.member)::uuid,
       ('61616161-0000-0000-0000-0000000300' || v.member)::uuid, v.type::visit_type,
       v.trainer::uuid, now() - n * interval '1 day',
       now() - n * interval '1 day' + interval '1 hour', '61616161-0000-0000-0000-00000000c001', true
from generate_series(1, 12) as n, (values
  ('03', 'group', '61616161-0000-0000-0000-00000000d001'),
  ('05', 'gym', null)
) as v(member, type, trainer);
insert into visits (gym_id, member_id, membership_id, visit_type, is_unpaid, checked_in_at,
                    checked_out_at, checked_in_by, is_backdated) values
  ('61616161-0000-0000-0000-00000000b001', '61616161-0000-0000-0000-000000020009', null, 'gym',
   true, now() - interval '2 days', now() - interval '2 days' + interval '1 hour',
   '61616161-0000-0000-0000-00000000c001', true);
grant select on clock to authenticated;

set local request.jwt.claims = '{"sub": "61616161-0000-0000-0000-00000000a001"}';
set local role authenticated;

-- Expired: S-03f asks, then [Produži članarinu] checks in ------------------------------------
select is(
  (select (r ->> 'result') || '|' || (r ->> 'reason') || '|' || (r ->> 'plan_name') || '|'
          || ((r ->> 'end_date')::date = (select d - 3 from clock))
   from (select begin_check_in('61616161-0000-0000-0000-000000020001') as r) s),
  'renew|expired|pgTAP Mjesečna|true',
  'D-109: an expired membership asks to renew it, naming the plan and its last day');
select is(
  (select count(*)::int from visits where member_id = '61616161-0000-0000-0000-000000020001'),
  0, 'D-109: S-03f records nothing until the desk chooses');
select is(
  (select r -> 'renewal' ->> 'plan_id'
   from (select begin_check_in('61616161-0000-0000-0000-000000020001') as r) s),
  '61616161-0000-0000-0000-00000000f001', 'D-109: S-08 preselects the plan that expired');
select is(
  (select (r -> 'check_in' ->> 'covered') || '|' || (r -> 'check_in' ->> 'visit_type') || '|'
          || coalesce(r ->> 'not_checked_in', '-')
   from (select sell_membership(p_member => '61616161-0000-0000-0000-000000020001',
           p_plan => '61616161-0000-0000-0000-00000000f001', p_trainer => null,
           p_amount => null, p_sessions => null, p_method => 'cash', p_check_in => true,
           p_manual => false) as r) s),
  'true|gym|-', 'D-109: [Produži članarinu] sells and checks the member in, covered');
select is(
  (select (m.start_date = (select d from clock)) || '|' || (v.membership_id = m.id)
   from visits v join memberships m on m.member_id = v.member_id and m.end_date > (select d from clock)
   where v.member_id = '61616161-0000-0000-0000-000000020001'),
  'true|true', 'D-109: the membership starts today and the visit is on it');

-- Never had one: [Neplaćeni dolazak] ----------------------------------------------------------
select is(
  (select (r ->> 'result') || '|' || (r ->> 'reason') || '|' || ((r ->> 'renewal') is null)
   from (select begin_check_in('61616161-0000-0000-0000-000000020002') as r) s),
  'renew|none|true', 'D-109: a member with no membership is asked too, with nothing to preselect');
select is(
  (select (r ->> 'result') || '|' || (r -> 'check_in' ->> 'visit_type') || '|'
          || (r -> 'check_in' ->> 'covered') || '|' || (r -> 'check_in' ->> 'unpaid_count')
   from (select check_in_unpaid('61616161-0000-0000-0000-000000020002', true) as r) s),
  'checked_in|gym|false|1', 'D-109: [Neplaćeni dolazak] records the unpaid visit (yellow)');
select is(
  (select is_manual from visits where member_id = '61616161-0000-0000-0000-000000020002'),
  true, 'BR-080: a manual start stays manual');

-- Sessions used up ------------------------------------------------------------------------------
select is(
  (select (r ->> 'result') || '|' || (r ->> 'reason') || '|' || (r ->> 'plan_name')
   from (select begin_check_in('61616161-0000-0000-0000-000000020003') as r) s),
  'renew|used_up|pgTAP Grupni', 'D-109: a Grupni with every session used asks at their class');
select is(
  (select (r -> 'check_in' ->> 'covered') || '|' || (r -> 'check_in' ->> 'visit_type')
   from (select sell_membership(p_member => '61616161-0000-0000-0000-000000020003',
           p_plan => '61616161-0000-0000-0000-00000000f003',
           p_trainer => '61616161-0000-0000-0000-00000000d001', p_amount => null,
           p_sessions => null, p_method => 'card',
           p_class_time => (select ts::time from clock), p_check_in => true,
           p_manual => false) as r) s),
  'true|group', 'D-109: the new Grupni checks the member in to their class');
select is(
  (select (v.class_slot_id = '61616161-0000-0000-0000-00000000e101') || '|'
          || (v.membership_id <> '61616161-0000-0000-0000-000000030003')
   from visits v where v.member_id = '61616161-0000-0000-0000-000000020003'
     and v.checked_out_at is null),
  'true|true', 'D-109: on the class now, using a session of the new Grupni');
select is(
  (select (r ->> 'result') || '|' || (r ->> 'reason')
   from (select begin_check_in('61616161-0000-0000-0000-000000020005') as r) s),
  'renew|used_up', 'D-109: a gym membership with every visit used asks too');

-- Outside the class: D-102 unchanged -----------------------------------------------------------
select is(
  (select (r ->> 'result') || '|' || (r -> 'check_in' ->> 'visit_type') || '|'
          || (r -> 'check_in' ->> 'covered')
   from (select begin_check_in('61616161-0000-0000-0000-000000020004') as r) s),
  'checked_in|gym|false', 'D-102: a valid Grupni outside the class is an unpaid gym visit at once');

-- When the sale records no visit -----------------------------------------------------------------
select is(
  (select (r ->> 'not_checked_in') || '|' || ((r ->> 'check_in') is null)
   from (select sell_membership(p_member => '61616161-0000-0000-0000-000000020006',
           p_plan => '61616161-0000-0000-0000-00000000f001', p_trainer => null,
           p_amount => null, p_sessions => null, p_method => 'cash',
           p_start_override => (select d + 1 from clock), p_check_in => true,
           p_manual => false) as r) s),
  'not_today|true', 'D-109: a start chosen for tomorrow records no visit today');
select is(
  (select r ->> 'result'
   from (select check_in_unpaid('61616161-0000-0000-0000-000000020007', false) as r) s),
  'checked_in', 'D-109: another desk records an unpaid visit meanwhile');
select is(
  (select (r ->> 'not_checked_in') || '|' || (r ->> 'linked_visits')
   from (select sell_membership(p_member => '61616161-0000-0000-0000-000000020007',
           p_plan => '61616161-0000-0000-0000-00000000f001', p_trainer => null,
           p_amount => null, p_sessions => null, p_method => 'cash', p_check_in => true,
           p_manual => false) as r) s),
  'inside|1', 'D-109: the sale still saves, linking that visit (BR-052 step 2), and adds none');
select is(
  (select (r ->> 'not_checked_in') || '|' || ((r ->> 'check_in') is null)
   from (select sell_membership(p_member => '61616161-0000-0000-0000-000000020008',
           p_plan => '61616161-0000-0000-0000-00000000f003',
           p_trainer => '61616161-0000-0000-0000-00000000d004', p_amount => null,
           p_sessions => null, p_method => 'cash',
           p_class_time => (select (ts + interval '1 minute')::time from clock),
           p_check_in => true, p_manual => false) as r) s),
  'no_class|true', 'D-106: a Grupni whose trainer holds no class today records no visit');

-- Older unpaid visits: from the first one (BR-052 step 2) ----------------------------------------
select is(
  (select ((r ->> 'start_date')::date = (select d - 2 from clock)) || '|' || (r ->> 'linked_visits')
          || '|' || (r -> 'check_in' ->> 'covered')
   from (select sell_membership(p_member => '61616161-0000-0000-0000-000000020009',
           p_plan => '61616161-0000-0000-0000-00000000f001', p_trainer => null,
           p_amount => null, p_sessions => null, p_method => 'cash', p_check_in => true,
           p_manual => false) as r) s),
  'true|1|true', 'D-109: the renewal starts at the first unpaid visit, links it and covers today');
select is(unlinked_unpaid_count('61616161-0000-0000-0000-000000020009'), 0,
  'US-10.1: nothing is left unpaid');

-- Internal functions and the gym ---------------------------------------------------------------
select throws_ok(
  $$select check_in_choice(null::staff, '61616161-0000-0000-0000-000000020001')$$,
  '42501', null, 'D-109: check_in_choice is not callable by staff');
select throws_ok(
  $$select check_in_after_sale(null::staff, '61616161-0000-0000-0000-000000020001', null, false)$$,
  '42501', null, 'D-109: check_in_after_sale is not callable by staff');
select throws_ok(
  $$select check_in_unpaid('61616161-0000-0000-0000-0000000209ff', false)$$,
  'P0001', 'E_FORBIDDEN', 'D-109: [Neplaćeni dolazak] only for a member of the caller''s gym');

reset role;
select * from finish();
