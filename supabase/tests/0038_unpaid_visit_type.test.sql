-- D-106 (migration 0058): with nothing valid today, a member whose latest membership was
-- Grupni only gets an unpaid group visit at their class, and one whose latest was
-- Personalni only an unpaid personal visit, so the next sale of that kind links it
-- (BR-052 step 2) and the unpaid badge clears. Everyone else still gets an unpaid gym
-- visit. "Prijavi odmah" records a visit only with a membership valid today, and checks
-- a new Grupni member in to their class today at any hour, or not at all on a day
-- without one.
select plan(20);

-- Fixtures --------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('58585858-0000-0000-0000-00000000a001', null),
  ('58585858-0000-0000-0000-00000000a002', null);
insert into gyms (id, name, timezone)
values ('58585858-0000-0000-0000-00000000b001', 'pgTAP Neplaceni tip', 'Europe/Podgorica');
insert into gym_settings (gym_id) values ('58585858-0000-0000-0000-00000000b001');
insert into staff (id, gym_id, user_id, role, full_name, username) values
  ('58585858-0000-0000-0000-00000000c001', '58585858-0000-0000-0000-00000000b001',
   '58585858-0000-0000-0000-00000000a001', 'receptionist', 'pgTAP Recepcija', 'pgtap.nt.recepcija'),
  ('58585858-0000-0000-0000-00000000c002', '58585858-0000-0000-0000-00000000b001',
   '58585858-0000-0000-0000-00000000a002', 'owner', 'pgTAP Vlasnik', 'pgtap.nt.vlasnik');
insert into shifts (id, gym_id, staff_id)
values ('58585858-0000-0000-0000-00000000c101', '58585858-0000-0000-0000-00000000b001',
        '58585858-0000-0000-0000-00000000c001');

-- Milena and Alina run group classes; Tamara and Tatjana personal training only (BR-023).
insert into trainers (id, gym_id, full_name) values
  ('58585858-0000-0000-0000-00000000d001', '58585858-0000-0000-0000-00000000b001', 'pgTAP Milena'),
  ('58585858-0000-0000-0000-00000000d002', '58585858-0000-0000-0000-00000000b001', 'pgTAP Tamara'),
  ('58585858-0000-0000-0000-00000000d003', '58585858-0000-0000-0000-00000000b001', 'pgTAP Tatjana'),
  ('58585858-0000-0000-0000-00000000d004', '58585858-0000-0000-0000-00000000b001', 'pgTAP Alina');
insert into trainer_finance (trainer_id, gym_id)
select id, gym_id from trainers where gym_id = '58585858-0000-0000-0000-00000000b001';
insert into programs (id, gym_id, name, kind) values
  ('58585858-0000-0000-0000-00000000e001', '58585858-0000-0000-0000-00000000b001', 'pgTAP Grupni', 'group'),
  ('58585858-0000-0000-0000-00000000e002', '58585858-0000-0000-0000-00000000b001', 'pgTAP Personalni', 'personal');
insert into trainer_programs (gym_id, trainer_id, program_id) values
  ('58585858-0000-0000-0000-00000000b001', '58585858-0000-0000-0000-00000000d001', '58585858-0000-0000-0000-00000000e001'),
  ('58585858-0000-0000-0000-00000000b001', '58585858-0000-0000-0000-00000000d004', '58585858-0000-0000-0000-00000000e001'),
  ('58585858-0000-0000-0000-00000000b001', '58585858-0000-0000-0000-00000000d002', '58585858-0000-0000-0000-00000000e002'),
  ('58585858-0000-0000-0000-00000000b001', '58585858-0000-0000-0000-00000000d003', '58585858-0000-0000-0000-00000000e002');

-- Milena's classes (local time): e101 today now, e102 today in three hours. Alina's e104
-- is held only on tomorrow's weekday.
create temporary table clock as
select date_trunc('minute', now() at time zone 'Europe/Podgorica') as ts,
       extract(isodow from now() at time zone 'Europe/Podgorica')::smallint as today,
       (extract(isodow from now() at time zone 'Europe/Podgorica')::int % 7 + 1)::smallint as tomorrow,
       gym_today('58585858-0000-0000-0000-00000000b001') as d;
insert into class_slots (id, gym_id, program_id, trainer_id, weekday, starts_at)
select v.id::uuid, '58585858-0000-0000-0000-00000000b001', '58585858-0000-0000-0000-00000000e001',
       v.trainer::uuid, v.weekday, v.starts_at
from clock c, lateral (values
  ('58585858-0000-0000-0000-00000000e101', '58585858-0000-0000-0000-00000000d001', c.today, c.ts::time),
  ('58585858-0000-0000-0000-00000000e102', '58585858-0000-0000-0000-00000000d001', c.today, (c.ts + interval '3 hours')::time),
  ('58585858-0000-0000-0000-00000000e104', '58585858-0000-0000-0000-00000000d004', c.tomorrow, (c.ts + interval '1 minute')::time)
) as v(id, trainer, weekday, starts_at);

-- Plans: f001 Mjesečna, f003 Grupni, f004 G+T, f005 Personalni.
insert into plans (id, gym_id, name, kind, duration_value, duration_unit, price,
                   covers_gym, covers_group, covers_personal,
                   gym_visit_limit, group_session_limit, requires_trainer) values
  ('58585858-0000-0000-0000-00000000f001', '58585858-0000-0000-0000-00000000b001', 'pgTAP Mjesečna',
   'gym', 1, 'month', 79, true, false, false, null, null, false),
  ('58585858-0000-0000-0000-00000000f003', '58585858-0000-0000-0000-00000000b001', 'pgTAP Grupni',
   'group', 1, 'month', 69, false, true, false, null, 12, true),
  ('58585858-0000-0000-0000-00000000f004', '58585858-0000-0000-0000-00000000b001', 'pgTAP G+T',
   'combo', 1, 'month', 99, true, true, false, null, 12, true),
  ('58585858-0000-0000-0000-00000000f005', '58585858-0000-0000-0000-00000000b001', 'pgTAP Personalni',
   'personal', 1, 'month', null, false, false, true, null, null, true);
insert into plan_finance (plan_id, gym_id)
select id, gym_id from plans where gym_id = '58585858-0000-0000-0000-00000000b001';

insert into members (id, gym_id, member_number, first_name, last_name, phone, email,
                     date_of_birth, created_by)
select ('58585858-0000-0000-0000-0000000200' || lpad(n::text, 2, '0'))::uuid,
       '58585858-0000-0000-0000-00000000b001', n, 'Član', 'Broj ' || n,
       '+3826758000' || lpad(n::text, 2, '0'), 'nt' || n || '@pgtap.invalid', '1990-01-01',
       '58585858-0000-0000-0000-00000000c002'
from generate_series(1, 7) as n;
-- BR-042: registrations continue after the fixture members.
insert into member_counters (gym_id, last_number)
values ('58585858-0000-0000-0000-00000000b001', 7);

-- Memberships that have ended: member, plan, trainer, fixed class time (by slot), start
-- and end offsets, coverage and limits, voided.
insert into memberships (id, gym_id, member_id, plan_id, trainer_id, class_time, start_date,
                         end_date, start_reason, covers_gym, covers_group, covers_personal,
                         gym_visit_limit, group_session_limit, personal_session_limit,
                         is_backdated, created_by, voided_at, void_reason)
select v.id::uuid, '58585858-0000-0000-0000-00000000b001',
       ('58585858-0000-0000-0000-0000000200' || v.member)::uuid,
       ('58585858-0000-0000-0000-00000000' || v.plan)::uuid,
       ('58585858-0000-0000-0000-00000000' || v.trainer)::uuid,
       (select starts_at from class_slots where id = ('58585858-0000-0000-0000-00000000' || v.slot)::uuid),
       c.d + v.s, c.d + v.e, 'fixture', v.g, v.gr, v.p, null, v.grl, v.pl, true,
       '58585858-0000-0000-0000-00000000c002',
       case when v.void then now() - interval '3 days' end,
       case when v.void then 'fixture' end
from clock c, (values
  -- 1: Grupni, class now.  2: Grupni, class in three hours.  3: Personalni with Tamara.
  ('58585858-0000-0000-0000-000000030001', '01', 'f003', 'd001', 'e101', -32, -2, false, true, false, 12::smallint, null::smallint, false),
  ('58585858-0000-0000-0000-000000030002', '02', 'f003', 'd001', 'e102', -32, -2, false, true, false, 12, null, false),
  ('58585858-0000-0000-0000-000000030003', '03', 'f005', 'd002', null, -32, -2, false, false, true, null, 10, false),
  -- 4: G+T.  5: Grupni whose trainer now runs personal training only.
  ('58585858-0000-0000-0000-000000030004', '04', 'f004', 'd001', 'e101', -32, -2, true, true, false, 12, null, false),
  ('58585858-0000-0000-0000-000000030005', '05', 'f003', 'd003', 'e101', -32, -2, false, true, false, 12, null, false),
  -- 6: Grupni, then a Mjesečna that ended later.  7: a voided Grupni only.
  ('58585858-0000-0000-0000-000000030006', '06', 'f003', 'd001', 'e101', -62, -32, false, true, false, 12, null, false),
  ('58585858-0000-0000-0000-000000030007', '06', 'f001', null, null, -32, -2, true, false, false, null, null, false),
  ('58585858-0000-0000-0000-000000030008', '07', 'f003', 'd001', 'e101', -32, -2, false, true, false, 12, null, true)
) as v(id, member, plan, trainer, slot, s, e, g, gr, p, grl, pl, void);

insert into card_batches (id, gym_id, quantity, created_by)
values ('58585858-0000-0000-0000-000000050001', '58585858-0000-0000-0000-00000000b001', 3,
        '58585858-0000-0000-0000-00000000c002');
insert into cards (gym_id, code, batch_id, status, member_id) values
  ('58585858-0000-0000-0000-00000000b001', '5858580001',
   '58585858-0000-0000-0000-000000050001', 'unassigned', null),
  ('58585858-0000-0000-0000-00000000b001', '5858580002',
   '58585858-0000-0000-0000-000000050001', 'unassigned', null),
  ('58585858-0000-0000-0000-00000000b001', '5858580003',
   '58585858-0000-0000-0000-000000050001', 'unassigned', null);
grant select on clock to authenticated;

set local request.jwt.claims = '{"sub": "58585858-0000-0000-0000-00000000a001"}';
set local role authenticated;

-- Grupni has ended ----------------------------------------------------------------------
select is(
  (select (r -> 'check_in' ->> 'visit_type') || '|' || (r -> 'check_in' ->> 'covered')
          || '|' || (r -> 'check_in' ->> 'unpaid_count')
   from (select begin_check_in('58585858-0000-0000-0000-000000020001') as r) s),
  'group|false|1', 'D-106: a Grupni that has ended, at their class: an unpaid group visit');
select is(
  (select (trainer_id = '58585858-0000-0000-0000-00000000d001') || '|'
          || (class_slot_id = '58585858-0000-0000-0000-00000000e101') || '|'
          || (membership_id is null) || '|' || is_unpaid
   from visits where member_id = '58585858-0000-0000-0000-000000020001'),
  'true|true|true|true', 'D-106: with that membership''s trainer and the class now');
select is(
  (sell_membership('58585858-0000-0000-0000-000000020001', '58585858-0000-0000-0000-00000000f003',
     '58585858-0000-0000-0000-00000000d001', null, null, 'cash', null,
     (select ts::time from clock)) ->> 'linked_visits')::int,
  1, 'D-106 (BR-052 step 2): paying for the next Grupni links the unpaid group visit');
select is(
  (select (v.membership_id = m.id) || '|' || (m.start_date = (select d from clock))
   from visits v join memberships m on m.member_id = v.member_id and m.voided_at is null
                                    and m.end_date >= (select d from clock)
   where v.member_id = '58585858-0000-0000-0000-000000020001'),
  'true|true', 'D-106: the new Grupni starts on the visit''s day and covers it');
select is(
  (select count(*)::int from visits
   where member_id = '58585858-0000-0000-0000-000000020001'
     and is_unpaid and membership_id is null),
  0, 'US-10.1: no unlinked unpaid visit is left, so the badge clears');

select is(
  begin_check_in('58585858-0000-0000-0000-000000020002') -> 'check_in' ->> 'visit_type',
  'gym', 'D-106: three hours before their class, still an unpaid gym visit');

-- Personalni has ended ------------------------------------------------------------------
select is(
  (select (r -> 'check_in' ->> 'visit_type') || '|' || (r -> 'check_in' ->> 'covered')
   from (select begin_check_in('58585858-0000-0000-0000-000000020003') as r) s),
  'personal|false', 'D-106: a Personalni that has ended: an unpaid personal visit');
select is(
  (select (trainer_id = '58585858-0000-0000-0000-00000000d002') || '|' || (class_slot_id is null)
   from visits where member_id = '58585858-0000-0000-0000-000000020003'),
  'true|true', 'D-106 (BR-076): with that membership''s trainer');
select is(
  cardinality((calc_membership_start('58585858-0000-0000-0000-000000020003',
                 '58585858-0000-0000-0000-00000000f005')).visit_ids),
  1, 'D-106 (BR-052 step 2): the next Personalni would link it');

-- Everyone else: an unpaid gym visit, as before ---------------------------------------------
select is(
  begin_check_in('58585858-0000-0000-0000-000000020004') ->> 'result', 'checked_in',
  'D-106: a G+T that has ended asks nothing');
select is(
  (select visit_type::text from visits where member_id = '58585858-0000-0000-0000-000000020004'),
  'gym', 'D-106: and gives an unpaid gym visit, which the next G+T covers');
select is(
  begin_check_in('58585858-0000-0000-0000-000000020005') -> 'check_in' ->> 'visit_type',
  'gym', 'D-106 (BR-023): a trainer who no longer runs group classes gives a gym visit');
select is(
  begin_check_in('58585858-0000-0000-0000-000000020006') -> 'check_in' ->> 'visit_type',
  'gym', 'D-106: the membership that ended last decides (a Mjesečna)');
select is(
  begin_check_in('58585858-0000-0000-0000-000000020007') -> 'check_in' ->> 'visit_type',
  'gym', 'D-106: a voided Grupni does not count');

-- "Prijavi odmah" at registration -----------------------------------------------------------
select is(
  (select (r ->> 'check_in') is null
   from (select register_member('5858580001', 'Nova', 'Bezcasa', '067 580 001',
           'r1@pgtap.invalid', '1999-09-09', '58585858-0000-0000-0000-00000000f003',
           '58585858-0000-0000-0000-00000000d004', null, null, 'cash', true,
           (select (ts + interval '1 minute')::time from clock)) as r) s),
  true, 'D-106: a new Grupni member on a day without their trainer''s class: no visit');
select is(
  (select count(*)::int from memberships ms join members m on m.id = ms.member_id
   where m.gym_id = '58585858-0000-0000-0000-00000000b001' and m.last_name = 'Bezcasa'),
  1, 'D-106: the member and the membership are still saved');
select is(
  (select r -> 'check_in' ->> 'covered'
   from (select register_member('5858580002', 'Nova', 'Kasnije', '067 580 002',
           'r2@pgtap.invalid', '1999-09-09', '58585858-0000-0000-0000-00000000f003',
           '58585858-0000-0000-0000-00000000d001', null, null, 'cash', true,
           (select (ts + interval '3 hours')::time from clock)) as r) s),
  'true', 'D-106: registered three hours before their class: a covered group visit');
select is(
  (select v.class_slot_id from visits v join members m on m.id = v.member_id
   where m.gym_id = '58585858-0000-0000-0000-00000000b001' and m.last_name = 'Kasnije'),
  '58585858-0000-0000-0000-00000000e102'::uuid,
  'D-106: to their own class, not the class nearest now');
select is(
  (select r -> 'check_in' ->> 'covered'
   from (select register_member('5858580003', 'Nova', 'Juce', '067 580 003',
           'r3@pgtap.invalid', '1999-09-09', '58585858-0000-0000-0000-00000000f001',
           null, null, null, 'cash', true, null, (select d - 1 from clock)) as r) s),
  'true', 'D-106: a start chosen yesterday is valid today, so the member is checked in');

-- Internal function ---------------------------------------------------------------------
select throws_ok(
  $$select trainer_class_today('58585858-0000-0000-0000-00000000b001',
      '58585858-0000-0000-0000-00000000d001', null)$$,
  '42501', null, 'D-106: trainer_class_today is not callable by staff');

reset role;
select * from finish();
