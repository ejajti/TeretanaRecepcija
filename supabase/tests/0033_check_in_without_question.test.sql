-- D-102 (BR-073): S-03a asks the visit type only when the memberships valid today cover
-- two or more types. Grupni only checks in to the member's own class (D-71, ±90 min) or,
-- outside it, as an unpaid gym visit; Personalni only checks in with its trainer; used-up
-- sessions give the unpaid (yellow or red) result; two gym memberships take the BR-074
-- default. A trainer who no longer qualifies still sends the desk to S-03a. "Prijavi
-- odmah" at registration records the visit the same way, except that a new Grupni member
-- is checked in to their class today at any hour (D-106, migration 0058).
select plan(27);

-- Fixtures --------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('52525252-0000-0000-0000-00000000a001', null),
  ('52525252-0000-0000-0000-00000000a002', null);
insert into gyms (id, name, timezone)
values ('52525252-0000-0000-0000-00000000b001', 'pgTAP Bez pitanja', 'Europe/Podgorica');
insert into gym_settings (gym_id) values ('52525252-0000-0000-0000-00000000b001');
insert into staff (id, gym_id, user_id, role, full_name, username) values
  ('52525252-0000-0000-0000-00000000c001', '52525252-0000-0000-0000-00000000b001',
   '52525252-0000-0000-0000-00000000a001', 'receptionist', 'pgTAP Recepcija', 'pgtap.bp.recepcija'),
  ('52525252-0000-0000-0000-00000000c002', '52525252-0000-0000-0000-00000000b001',
   '52525252-0000-0000-0000-00000000a002', 'owner', 'pgTAP Vlasnik', 'pgtap.bp.vlasnik');
insert into shifts (id, gym_id, staff_id)
values ('52525252-0000-0000-0000-00000000c101', '52525252-0000-0000-0000-00000000b001',
        '52525252-0000-0000-0000-00000000c001');

-- Milena runs group classes; Tamara and Tatjana personal training only (BR-023).
insert into trainers (id, gym_id, full_name) values
  ('52525252-0000-0000-0000-00000000d001', '52525252-0000-0000-0000-00000000b001', 'pgTAP Milena'),
  ('52525252-0000-0000-0000-00000000d002', '52525252-0000-0000-0000-00000000b001', 'pgTAP Tamara'),
  ('52525252-0000-0000-0000-00000000d003', '52525252-0000-0000-0000-00000000b001', 'pgTAP Tatjana');
insert into trainer_finance (trainer_id, gym_id)
select id, gym_id from trainers where gym_id = '52525252-0000-0000-0000-00000000b001';
insert into programs (id, gym_id, name, kind) values
  ('52525252-0000-0000-0000-00000000e001', '52525252-0000-0000-0000-00000000b001', 'pgTAP Grupni', 'group'),
  ('52525252-0000-0000-0000-00000000e002', '52525252-0000-0000-0000-00000000b001', 'pgTAP Personalni', 'personal');
insert into trainer_programs (gym_id, trainer_id, program_id) values
  ('52525252-0000-0000-0000-00000000b001', '52525252-0000-0000-0000-00000000d001', '52525252-0000-0000-0000-00000000e001'),
  ('52525252-0000-0000-0000-00000000b001', '52525252-0000-0000-0000-00000000d002', '52525252-0000-0000-0000-00000000e002'),
  ('52525252-0000-0000-0000-00000000b001', '52525252-0000-0000-0000-00000000d003', '52525252-0000-0000-0000-00000000e002');

-- Milena's classes (local time): e101 today now, e102 today in three hours, e103 a minute
-- from now but only on tomorrow's weekday.
create temporary table clock as
select date_trunc('minute', now() at time zone 'Europe/Podgorica') as ts,
       extract(isodow from now() at time zone 'Europe/Podgorica')::smallint as today,
       (extract(isodow from now() at time zone 'Europe/Podgorica')::int % 7 + 1)::smallint as tomorrow,
       gym_today('52525252-0000-0000-0000-00000000b001') as d;
insert into class_slots (id, gym_id, program_id, trainer_id, weekday, starts_at)
select v.id::uuid, '52525252-0000-0000-0000-00000000b001', '52525252-0000-0000-0000-00000000e001',
       '52525252-0000-0000-0000-00000000d001', v.weekday, v.starts_at
from clock c, lateral (values
  ('52525252-0000-0000-0000-00000000e101', c.today, c.ts::time),
  ('52525252-0000-0000-0000-00000000e102', c.today, (c.ts + interval '3 hours')::time),
  ('52525252-0000-0000-0000-00000000e103', c.tomorrow, (c.ts + interval '1 minute')::time)
) as v(id, weekday, starts_at);

-- Plans: f001 Mjesečna, f003 Grupni, f004 G+T, f005 Personalni.
insert into plans (id, gym_id, name, kind, duration_value, duration_unit, price,
                   covers_gym, covers_group, covers_personal,
                   gym_visit_limit, group_session_limit, requires_trainer) values
  ('52525252-0000-0000-0000-00000000f001', '52525252-0000-0000-0000-00000000b001', 'pgTAP Mjesečna',
   'gym', 1, 'month', 79, true, false, false, null, null, false),
  ('52525252-0000-0000-0000-00000000f003', '52525252-0000-0000-0000-00000000b001', 'pgTAP Grupni',
   'group', 1, 'month', 69, false, true, false, null, 12, true),
  ('52525252-0000-0000-0000-00000000f004', '52525252-0000-0000-0000-00000000b001', 'pgTAP G+T',
   'combo', 1, 'month', 99, true, true, false, null, 12, true),
  ('52525252-0000-0000-0000-00000000f005', '52525252-0000-0000-0000-00000000b001', 'pgTAP Personalni',
   'personal', 1, 'month', null, false, false, true, null, null, true);
insert into plan_finance (plan_id, gym_id)
select id, gym_id from plans where gym_id = '52525252-0000-0000-0000-00000000b001';

insert into members (id, gym_id, member_number, first_name, last_name, phone, email,
                     date_of_birth, created_by)
select ('52525252-0000-0000-0000-0000000200' || lpad(n::text, 2, '0'))::uuid,
       '52525252-0000-0000-0000-00000000b001', n, 'Član', 'Broj ' || n,
       '+3826752000' || lpad(n::text, 2, '0'), 'bp' || n || '@pgtap.invalid', '1990-01-01',
       '52525252-0000-0000-0000-00000000c002'
from generate_series(1, 13) as n;
-- BR-042: registrations continue after the fixture members.
insert into member_counters (gym_id, last_number)
values ('52525252-0000-0000-0000-00000000b001', 13);

-- Memberships around today: member, plan, trainer, fixed class time (by slot), start and
-- end offsets, coverage and limits.
insert into memberships (id, gym_id, member_id, plan_id, trainer_id, class_time, start_date,
                         end_date, start_reason, covers_gym, covers_group, covers_personal,
                         gym_visit_limit, group_session_limit, personal_session_limit,
                         is_backdated, created_by)
select v.id::uuid, '52525252-0000-0000-0000-00000000b001',
       ('52525252-0000-0000-0000-0000000200' || v.member)::uuid,
       ('52525252-0000-0000-0000-00000000' || v.plan)::uuid,
       ('52525252-0000-0000-0000-00000000' || v.trainer)::uuid,
       (select starts_at from class_slots where id = ('52525252-0000-0000-0000-00000000' || v.slot)::uuid),
       c.d + v.s, c.d + v.e, 'fixture', v.g, v.gr, v.p, null, v.grl, v.pl, true,
       '52525252-0000-0000-0000-00000000c002'
from clock c, (values
  -- 1: Grupni, class now.  2: class in three hours.  3: class only tomorrow.
  ('52525252-0000-0000-0000-000000030001', '01', 'f003', 'd001', 'e101', -5, 25, false, true, false, 12::smallint, null::smallint),
  ('52525252-0000-0000-0000-000000030002', '02', 'f003', 'd001', 'e102', -5, 25, false, true, false, 12, null),
  ('52525252-0000-0000-0000-000000030003', '03', 'f003', 'd001', 'e103', -5, 25, false, true, false, 12, null),
  -- 4: Grupni with its one session used (below).  5: Grupni sold before D-71, no time.
  ('52525252-0000-0000-0000-000000030004', '04', 'f003', 'd001', 'e101', -5, 25, false, true, false, 1, null),
  ('52525252-0000-0000-0000-000000030005', '05', 'f003', 'd001', null, -5, 25, false, true, false, 12, null),
  -- 6: Grupni whose trainer no longer runs group classes.
  ('52525252-0000-0000-0000-000000030006', '06', 'f003', 'd003', 'e101', -5, 25, false, true, false, 12, null),
  -- 7: Personalni with Tamara.  8: Personalni with its one session used (below).
  ('52525252-0000-0000-0000-000000030007', '07', 'f005', 'd002', null, -5, 25, false, false, true, null, 10),
  ('52525252-0000-0000-0000-000000030008', '08', 'f005', 'd002', null, -5, 25, false, false, true, null, 1),
  -- 9: G+T.  10: Mjesečna and Personalni.  11: Mjesečna and Grupni.
  ('52525252-0000-0000-0000-000000030009', '09', 'f004', 'd001', 'e101', -5, 25, true, true, false, 12, null),
  ('52525252-0000-0000-0000-000000030010', '10', 'f001', null, null, -5, 25, true, false, false, null, null),
  ('52525252-0000-0000-0000-000000030011', '10', 'f005', 'd002', null, -5, 25, false, false, true, null, 10),
  ('52525252-0000-0000-0000-000000030012', '11', 'f001', null, null, -5, 25, true, false, false, null, null),
  ('52525252-0000-0000-0000-000000030013', '11', 'f003', 'd001', 'e101', -5, 25, false, true, false, 12, null),
  -- 12: two Mjesečna, the second ending sooner (BR-074).  13: Grupni that has ended.
  ('52525252-0000-0000-0000-000000030014', '12', 'f001', null, null, -5, 25, true, false, false, null, null),
  ('52525252-0000-0000-0000-000000030015', '12', 'f001', null, null, -20, 10, true, false, false, null, null),
  ('52525252-0000-0000-0000-000000030016', '13', 'f003', 'd001', 'e101', -32, -2, false, true, false, 12, null)
) as v(id, member, plan, trainer, slot, s, e, g, gr, p, grl, pl);

insert into visits (gym_id, member_id, membership_id, visit_type, trainer_id, checked_in_at,
                    checked_out_at, checked_in_by, is_backdated) values
  ('52525252-0000-0000-0000-00000000b001', '52525252-0000-0000-0000-000000020004',
   '52525252-0000-0000-0000-000000030004', 'group', '52525252-0000-0000-0000-00000000d001',
   now() - interval '2 days', now() - interval '2 days' + interval '1 hour',
   '52525252-0000-0000-0000-00000000c001', true),
  ('52525252-0000-0000-0000-00000000b001', '52525252-0000-0000-0000-000000020008',
   '52525252-0000-0000-0000-000000030008', 'personal', '52525252-0000-0000-0000-00000000d002',
   now() - interval '2 days', now() - interval '2 days' + interval '1 hour',
   '52525252-0000-0000-0000-00000000c001', true);

insert into card_batches (id, gym_id, quantity, created_by)
values ('52525252-0000-0000-0000-000000050001', '52525252-0000-0000-0000-00000000b001', 4,
        '52525252-0000-0000-0000-00000000c002');
insert into cards (gym_id, code, batch_id, status, member_id) values
  ('52525252-0000-0000-0000-00000000b001', '5252520001',
   '52525252-0000-0000-0000-000000050001', 'active', '52525252-0000-0000-0000-000000020001'),
  ('52525252-0000-0000-0000-00000000b001', '5252520002',
   '52525252-0000-0000-0000-000000050001', 'unassigned', null),
  ('52525252-0000-0000-0000-00000000b001', '5252520003',
   '52525252-0000-0000-0000-000000050001', 'unassigned', null),
  ('52525252-0000-0000-0000-00000000b001', '5252520004',
   '52525252-0000-0000-0000-000000050001', 'unassigned', null);
-- The registrations below pick the class times of e101 and e102.
grant select on clock to authenticated;

set local request.jwt.claims = '{"sub": "52525252-0000-0000-0000-00000000a001"}';
set local role authenticated;

-- Grupni only -------------------------------------------------------------------------
select is(scan_card('5252520001') ->> 'result', 'checked_in',
  'D-102: a Grupni-only member''s scan in their class asks nothing');
select is(
  (select visit_type::text || '|' || (membership_id = '52525252-0000-0000-0000-000000030001')
          || '|' || (trainer_id = '52525252-0000-0000-0000-00000000d001')
          || '|' || (class_slot_id = '52525252-0000-0000-0000-00000000e101')
          || '|' || is_unpaid || '|' || is_manual
   from visits where member_id = '52525252-0000-0000-0000-000000020001'),
  'group|true|true|true|false|false',
  'D-102: a group visit on the membership, with its trainer and the member''s class now');
select is(
  (select (r -> 'check_in' ->> 'visit_type') || '|' || (r -> 'check_in' ->> 'covered')
          || '|' || (r -> 'check_in' ->> 'unpaid_count')
   from (select begin_check_in('52525252-0000-0000-0000-000000020002') as r) s),
  'gym|false|1', 'D-102: three hours before their class, an unpaid gym visit (yellow)');
select is(
  (select (r -> 'check_in' ->> 'visit_type') || '|' || (r -> 'check_in' ->> 'covered')
          || '|' || (r -> 'check_in' ->> 'unpaid_count')
   from (select begin_check_in('52525252-0000-0000-0000-000000020003') as r) s),
  'gym|false|1', 'D-102: on a day their class is not held, an unpaid gym visit too');
select is(
  (select (r -> 'check_in' ->> 'visit_type') || '|' || (r -> 'check_in' ->> 'covered')
          || '|' || (r -> 'check_in' ->> 'unpaid_count')
   from (select begin_check_in('52525252-0000-0000-0000-000000020004') as r) s),
  'group|false|1', 'D-102: sessions used up, an unpaid group visit and the yellow dialog');
select is(
  (select (trainer_id = '52525252-0000-0000-0000-00000000d001') || '|'
          || (class_slot_id = '52525252-0000-0000-0000-00000000e101')
   from visits where member_id = '52525252-0000-0000-0000-000000020004' and checked_out_at is null),
  'true|true', 'D-102: still with the membership''s trainer and the class now');
select is(
  begin_check_in('52525252-0000-0000-0000-000000020005') -> 'check_in' ->> 'covered',
  'true', 'D-102: a membership with no fixed class time checks in too');
select is(
  (select (class_slot_id = '52525252-0000-0000-0000-00000000e101')::text
   from visits where member_id = '52525252-0000-0000-0000-000000020005'),
  'true', 'D-102 and BR-075: to the trainer''s class nearest now');
select is(begin_check_in('52525252-0000-0000-0000-000000020006') ->> 'result', 'choose',
  'D-102 (BR-023, BR-075): a trainer who no longer runs group classes is chosen on S-03a');

-- Personalni only ---------------------------------------------------------------------
select is(
  (select (r -> 'check_in' ->> 'visit_type') || '|' || (r -> 'check_in' ->> 'covered')
          || '|' || (r -> 'check_in' ->> 'remaining')
   from (select begin_check_in('52525252-0000-0000-0000-000000020007') as r) s),
  'personal|true|9', 'D-102: a Personalni-only member is checked in at once, 9 of 10 left');
select is(
  (select (trainer_id = '52525252-0000-0000-0000-00000000d002') || '|'
          || (class_slot_id is null) || '|' || is_manual
   from visits where member_id = '52525252-0000-0000-0000-000000020007'),
  'true|true|true', 'D-102 and BR-076: with the membership''s trainer, no class, marked manual');
select is(
  (select (r -> 'check_in' ->> 'visit_type') || '|' || (r -> 'check_in' ->> 'covered')
          || '|' || (r -> 'check_in' ->> 'unpaid_count')
   from (select begin_check_in('52525252-0000-0000-0000-000000020008') as r) s),
  'personal|false|1', 'D-102: sessions used up, an unpaid personal visit and the yellow dialog');

-- Two or more types: S-03a as before ----------------------------------------------------
select is(begin_check_in('52525252-0000-0000-0000-000000020009') ->> 'result', 'choose',
  'D-102: G+T still asks');
select is(
  (select (r -> 'options' ->> 'types') || '|' || (r -> 'options' ->> 'preselect')
   from (select begin_check_in('52525252-0000-0000-0000-000000020009') as r) s),
  '["gym","group"]|gym', 'BR-073: Teretana and Grupni, Teretana preselected');
select is(begin_check_in('52525252-0000-0000-0000-000000020010') ->> 'result', 'choose',
  'D-102: Mjesečna with Personalni asks');
select is(
  begin_check_in('52525252-0000-0000-0000-000000020010') -> 'options' ->> 'types',
  '["gym","personal"]', 'BR-073: Teretana and Personalni');
select is(begin_check_in('52525252-0000-0000-0000-000000020011') ->> 'result', 'choose',
  'D-102: Mjesečna with a separate Grupni asks, as G+T does');
select is(
  (select count(*)::int from visits where member_id in (
     '52525252-0000-0000-0000-000000020006', '52525252-0000-0000-0000-000000020009',
     '52525252-0000-0000-0000-000000020010', '52525252-0000-0000-0000-000000020011')),
  0, 'US-04.3 AC2: a question records nothing until it is answered');

-- Teretana only -----------------------------------------------------------------------
select is(begin_check_in('52525252-0000-0000-0000-000000020012') ->> 'result', 'checked_in',
  'D-102: two gym memberships no longer need the selector');
select is(
  (select membership_id from visits where member_id = '52525252-0000-0000-0000-000000020012'),
  '52525252-0000-0000-0000-000000030015'::uuid, 'BR-074: the earliest-ending one is taken');
select is(
  (select (r -> 'check_in' ->> 'visit_type') || '|' || (r -> 'check_in' ->> 'covered')
          || '|' || (r -> 'check_in' ->> 'unpaid_count')
   from (select begin_check_in('52525252-0000-0000-0000-000000020013') as r) s),
  'group|false|1', 'D-106: with a Grupni that has ended, at their class an unpaid group visit');

-- "Prijavi odmah" at registration (D-31) follows the same rule -----------------------------
select is(
  (select (r -> 'check_in' ->> 'visit_type') || '|' || (r -> 'check_in' ->> 'covered')
   from (select register_member('5252520002', 'Nova', 'Utermin', '067 520 002',
           'r2@pgtap.invalid', '1999-09-09', '52525252-0000-0000-0000-00000000f003',
           '52525252-0000-0000-0000-00000000d001', null, null, 'cash', true,
           (select ts::time from clock)) as r) s),
  'group|true', 'D-102: a new Grupni member registered at their class: a covered group visit');
select is(
  (select (r -> 'check_in' ->> 'visit_type') || '|' || (r -> 'check_in' ->> 'covered')
   from (select register_member('5252520003', 'Nova', 'Vantermina', '067 520 003',
           'r3@pgtap.invalid', '1999-09-09', '52525252-0000-0000-0000-00000000f003',
           '52525252-0000-0000-0000-00000000d001', null, null, 'cash', true,
           (select (ts + interval '3 hours')::time from clock)) as r) s),
  'group|true', 'D-106: registered three hours before their class: a covered group visit');
select is(
  (select (r -> 'check_in' ->> 'visit_type') || '|' || (r -> 'check_in' ->> 'covered')
   from (select register_member('5252520004', 'Nova', 'Kombinovana', '067 520 004',
           'r4@pgtap.invalid', '1999-09-09', '52525252-0000-0000-0000-00000000f004',
           '52525252-0000-0000-0000-00000000d001', null, null, 'cash', true,
           (select ts::time from clock)) as r) s),
  'gym|true', 'D-31: a new G+T member is checked in to the gym, as before, without a question');

-- Internal functions ------------------------------------------------------------------
select throws_ok(
  $$select member_class_slot('52525252-0000-0000-0000-00000000b001',
      '52525252-0000-0000-0000-00000000d001', null)$$,
  '42501', null, 'D-102: member_class_slot is not callable by staff');
select throws_ok(
  $$select start_check_in_choose('52525252-0000-0000-0000-000000020009', false, false)$$,
  '42501', null, 'D-102: start_check_in_choose is not callable by staff');
select throws_ok(
  $$select auto_check_in(current_staff(), '52525252-0000-0000-0000-000000020009', false)$$,
  '42501', null, 'D-102: auto_check_in is not callable by staff');

reset role;
select * from finish();
