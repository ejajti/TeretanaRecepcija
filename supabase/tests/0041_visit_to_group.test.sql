-- D-110 (migration 0063): S-07 [Ipak grupni trening] turns an unlinked unpaid gym visit
-- into a group visit with the chosen trainer and class, linked to the group membership
-- that covers its day, and audits the change (BR-096). Refused when the visit is not an
-- unpaid gym visit, the member already has a group visit that day, or no membership
-- covers group training that day.
select plan(14);

-- Fixtures --------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('62626262-0000-0000-0000-00000000a001', null),
  ('62626262-0000-0000-0000-00000000a002', null);
insert into gyms (id, name, timezone)
values ('62626262-0000-0000-0000-00000000b001', 'pgTAP Ipak grupni', 'Europe/Podgorica');
insert into gym_settings (gym_id) values ('62626262-0000-0000-0000-00000000b001');
insert into staff (id, gym_id, user_id, role, full_name, username) values
  ('62626262-0000-0000-0000-00000000c001', '62626262-0000-0000-0000-00000000b001',
   '62626262-0000-0000-0000-00000000a001', 'receptionist', 'pgTAP Recepcija', 'pgtap.ig.recepcija'),
  ('62626262-0000-0000-0000-00000000c002', '62626262-0000-0000-0000-00000000b001',
   '62626262-0000-0000-0000-00000000a002', 'owner', 'pgTAP Vlasnik', 'pgtap.ig.vlasnik');

-- Milena runs group classes, Tamara personal training only (BR-023).
insert into trainers (id, gym_id, full_name) values
  ('62626262-0000-0000-0000-00000000d001', '62626262-0000-0000-0000-00000000b001', 'pgTAP Milena'),
  ('62626262-0000-0000-0000-00000000d002', '62626262-0000-0000-0000-00000000b001', 'pgTAP Tamara');
insert into programs (id, gym_id, name, kind) values
  ('62626262-0000-0000-0000-00000000e001', '62626262-0000-0000-0000-00000000b001', 'pgTAP Grupni', 'group'),
  ('62626262-0000-0000-0000-00000000e002', '62626262-0000-0000-0000-00000000b001', 'pgTAP Personalni', 'personal');
insert into trainer_programs (gym_id, trainer_id, program_id) values
  ('62626262-0000-0000-0000-00000000b001', '62626262-0000-0000-0000-00000000d001', '62626262-0000-0000-0000-00000000e001'),
  ('62626262-0000-0000-0000-00000000b001', '62626262-0000-0000-0000-00000000d002', '62626262-0000-0000-0000-00000000e002');

-- The visits are two days ago (X), when Milena held a class at 12:00.
create temporary table clock as
select gym_today('62626262-0000-0000-0000-00000000b001') - 2 as x;
insert into class_slots (id, gym_id, program_id, trainer_id, weekday, starts_at)
select '62626262-0000-0000-0000-00000000e101', '62626262-0000-0000-0000-00000000b001',
       '62626262-0000-0000-0000-00000000e001', '62626262-0000-0000-0000-00000000d001',
       extract(isodow from x)::smallint, time '12:00'
from clock;

insert into plans (id, gym_id, name, kind, duration_value, duration_unit, price,
                   covers_gym, covers_group, covers_personal,
                   gym_visit_limit, group_session_limit, requires_trainer) values
  ('62626262-0000-0000-0000-00000000f003', '62626262-0000-0000-0000-00000000b001', 'pgTAP Grupni',
   'group', 1, 'month', 69, false, true, false, null, 12, true);

insert into members (id, gym_id, member_number, first_name, last_name, phone, email,
                     date_of_birth, created_by)
select ('62626262-0000-0000-0000-0000000200' || lpad(n::text, 2, '0'))::uuid,
       '62626262-0000-0000-0000-00000000b001', n, 'Član', 'Broj ' || n,
       '+3826762000' || lpad(n::text, 2, '0'), 'ig' || n || '@pgtap.invalid', '1990-01-01',
       '62626262-0000-0000-0000-00000000c002'
from generate_series(1, 6) as n;

-- Grupni with Milena at 18:00: valid around X for 1, 2, 3 and 6; for 4 with its one
-- session used; for 5 only from the day after X.
insert into memberships (id, gym_id, member_id, plan_id, trainer_id, class_time, start_date,
                         end_date, start_reason, covers_gym, covers_group, covers_personal,
                         group_session_limit, is_backdated, created_by)
select ('62626262-0000-0000-0000-0000000300' || v.member)::uuid,
       '62626262-0000-0000-0000-00000000b001',
       ('62626262-0000-0000-0000-0000000200' || v.member)::uuid,
       '62626262-0000-0000-0000-00000000f003', '62626262-0000-0000-0000-00000000d001',
       time '18:00', c.x + v.s, c.x + v.s + 30, 'fixture', false, true, false, v.lim, true,
       '62626262-0000-0000-0000-00000000c002'
from clock c, (values ('01', -10, 12::smallint), ('02', -10, 12), ('03', -10, 12),
                      ('04', -10, 1), ('05', 1, 12), ('06', -10, 12)) as v(member, s, lim);

-- An unpaid gym visit at 12:05 on X for each member (D-102); member 3 also has a group
-- visit that day, member 4 a group visit the day before that used its only session.
insert into visits (id, gym_id, member_id, membership_id, visit_type, trainer_id, is_unpaid,
                    checked_in_at, checked_out_at, checked_in_by, is_backdated)
select ('62626262-0000-0000-0000-0000000400' || v.id)::uuid,
       '62626262-0000-0000-0000-00000000b001',
       ('62626262-0000-0000-0000-0000000200' || v.member)::uuid,
       case when v.linked then ('62626262-0000-0000-0000-0000000300' || v.member)::uuid end,
       v.type::visit_type,
       case when v.type = 'group' then '62626262-0000-0000-0000-00000000d001'::uuid end,
       not v.linked, (c.x + v.day + v.at) at time zone 'Europe/Podgorica',
       (c.x + v.day + v.at + interval '1 hour') at time zone 'Europe/Podgorica',
       '62626262-0000-0000-0000-00000000c001', false
from clock c, (values
  ('01', '01', 'gym', false, 0, time '12:05'),
  ('02', '02', 'gym', false, 0, time '12:05'),
  ('03', '03', 'gym', false, 0, time '12:05'),
  ('31', '03', 'group', true, 0, time '17:55'),
  ('04', '04', 'gym', false, 0, time '12:05'),
  ('41', '04', 'group', true, -1, time '17:55'),
  ('05', '05', 'gym', false, 0, time '12:05'),
  ('06', '06', 'gym', false, 0, time '12:05')
) as v(id, member, type, linked, day, at);

set local request.jwt.claims = '{"sub": "62626262-0000-0000-0000-00000000a001"}';
set local role authenticated;

-- [Ipak grupni trening] ------------------------------------------------------------------
select is(
  (select (r ->> 'membership_id') || '|' || (r ->> 'unpaid_count')
   from (select visit_to_group('62626262-0000-0000-0000-000000040001',
           '62626262-0000-0000-0000-00000000d001', time '12:00') as r) s),
  '62626262-0000-0000-0000-000000030001|0',
  'D-110: a receptionist turns the visit into a group visit; nothing is left unpaid');
select is(
  (select visit_type::text || '|' || (trainer_id = '62626262-0000-0000-0000-00000000d001') || '|'
          || (class_slot_id = '62626262-0000-0000-0000-00000000e101') || '|' || is_unpaid
   from visits where id = '62626262-0000-0000-0000-000000040001'),
  'group|true|true|true',
  'D-110: with Milena and her 12:00 class that day; is_unpaid stays as history');
select is(membership_used('62626262-0000-0000-0000-000000030001', 'group'), 1,
  'D-110 (BR-053): it uses one of the Grupni''s sessions');
select is(
  (select (r ->> 'unpaid_count') || '|'
          || (select (class_slot_id is null)::text from visits
              where id = '62626262-0000-0000-0000-000000040002')
   from (select visit_to_group('62626262-0000-0000-0000-000000040002',
           '62626262-0000-0000-0000-00000000d001', null) as r) s),
  '0|true', 'D-110: without a class from the schedule when the trainer moved it');

-- Refusals --------------------------------------------------------------------------------
select throws_ok(
  $$select visit_to_group('62626262-0000-0000-0000-000000040003',
      '62626262-0000-0000-0000-00000000d001', null)$$,
  'P0001', 'E_GROUP_VISIT_EXISTS', 'D-110: not when the member has a group visit that day');
select throws_ok(
  $$select visit_to_group('62626262-0000-0000-0000-000000040004',
      '62626262-0000-0000-0000-00000000d001', null)$$,
  'P0001', 'E_NO_GROUP_MEMBERSHIP', 'D-110 (BR-053): not when the Grupni''s sessions are used up');
select throws_ok(
  $$select visit_to_group('62626262-0000-0000-0000-000000040005',
      '62626262-0000-0000-0000-00000000d001', null)$$,
  'P0001', 'E_NO_GROUP_MEMBERSHIP', 'D-110: not before the Grupni starts');
select throws_ok(
  $$select visit_to_group('62626262-0000-0000-0000-000000040001',
      '62626262-0000-0000-0000-00000000d001', null)$$,
  'P0001', 'E_VISIT_NOT_UNPAID_GYM', 'D-110: a visit already turned is not turned again');
select throws_ok(
  $$select visit_to_group('62626262-0000-0000-0000-000000040006',
      '62626262-0000-0000-0000-00000000d002', null)$$,
  'P0001', 'E_TRAINER_NOT_ASSIGNED', 'D-110 (BR-075): the trainer must run group classes');
select throws_ok(
  $$select visit_to_group('62626262-0000-0000-0000-000000040006',
      '62626262-0000-0000-0000-00000000d001', time '07:00')$$,
  'P0001', 'E_VALIDATION', 'D-110 (BR-075): the class must be the trainer''s on that weekday');
select throws_ok(
  $$select visit_to_group('62626262-0000-0000-0000-000000040006', null, null)$$,
  'P0001', 'E_TRAINER_REQUIRED', 'D-110 (BR-075): a trainer is required');
select throws_ok(
  $$select visit_to_group('62626262-0000-0000-0000-0000000409ff',
      '62626262-0000-0000-0000-00000000d001', null)$$,
  'P0001', 'E_FORBIDDEN', 'D-110: only a visit of the caller''s gym');
select is(
  (select visit_type::text || '|' || is_unpaid || '|' || (membership_id is null)
   from visits where id = '62626262-0000-0000-0000-000000040006'),
  'gym|true|true', 'D-110: a refused change leaves the visit as it was');

-- BR-096 ------------------------------------------------------------------------------------
reset role;
select is(
  (select count(*)::int from audit_log
   where table_name = 'visits' and row_id = '62626262-0000-0000-0000-000000040001'
     and action = 'update' and changed_by = '62626262-0000-0000-0000-00000000c001'
     and old_data ->> 'visit_type' = 'gym' and new_data ->> 'visit_type' = 'group'),
  1, 'BR-096: the change is in the audit log with who made it');

select * from finish();
