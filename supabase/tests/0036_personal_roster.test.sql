-- D-105 (BR-027a): S-29 Treneri, tab Personalni. Every role sees the personal memberships
-- that are valid today or start later, by trainer, with the day paid, the last valid day
-- and the personal sessions used. The amounts stay the owner's and the admin's, through
-- fin_roster_prices (BR-157).
select plan(24);

-- Fixtures ------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('36363636-0000-0000-0000-00000000a001', null),
  ('36363636-0000-0000-0000-00000000a002', null),
  ('36363636-0000-0000-0000-00000000a003', null),
  ('36363636-0000-0000-0000-00000000a004', null),
  ('36363636-0000-0000-0000-00000000a005', null);

insert into gyms (id, name, timezone) values
  ('36363636-0000-0000-0000-00000000b001', 'pgTAP Personalni', 'Europe/Podgorica'),
  ('36363636-0000-0000-0000-00000000b002', 'pgTAP Druga', 'Europe/Podgorica');
insert into gym_settings (gym_id) values
  ('36363636-0000-0000-0000-00000000b001'),
  ('36363636-0000-0000-0000-00000000b002');

-- a005 is signed in to Auth but is nobody's staff.
insert into staff (id, gym_id, user_id, role, full_name, username) values
  ('36363636-0000-0000-0000-00000000c001', '36363636-0000-0000-0000-00000000b001',
   '36363636-0000-0000-0000-00000000a001', 'receptionist', 'pgTAP Recepcija', 'pgtap.pr.recepcija'),
  ('36363636-0000-0000-0000-00000000c002', '36363636-0000-0000-0000-00000000b001',
   '36363636-0000-0000-0000-00000000a002', 'owner', 'pgTAP Vlasnik', 'pgtap.pr.vlasnik'),
  ('36363636-0000-0000-0000-00000000c003', '36363636-0000-0000-0000-00000000b001',
   '36363636-0000-0000-0000-00000000a003', 'manager', 'pgTAP Menadžer', 'pgtap.pr.menadzer'),
  ('36363636-0000-0000-0000-00000000c004', '36363636-0000-0000-0000-00000000b002',
   '36363636-0000-0000-0000-00000000a004', 'owner', 'pgTAP Drugi Vlasnik', 'pgtap.pr.drugi');

-- d001 Julija and d002 Tamara train Personalni; d003 Stara did, but is inactive now;
-- d004 trains only group; d005 only an inactive personal program; d006 is another gym's.
insert into trainers (id, gym_id, full_name, is_active) values
  ('36363636-0000-0000-0000-00000000d001', '36363636-0000-0000-0000-00000000b001', 'pgTAP Julija', true),
  ('36363636-0000-0000-0000-00000000d002', '36363636-0000-0000-0000-00000000b001', 'pgTAP Tamara', true),
  ('36363636-0000-0000-0000-00000000d003', '36363636-0000-0000-0000-00000000b001', 'pgTAP Stara', false),
  ('36363636-0000-0000-0000-00000000d004', '36363636-0000-0000-0000-00000000b001', 'pgTAP Grupna', true),
  ('36363636-0000-0000-0000-00000000d005', '36363636-0000-0000-0000-00000000b001', 'pgTAP Bez programa', true),
  ('36363636-0000-0000-0000-00000000d006', '36363636-0000-0000-0000-00000000b002', 'pgTAP Druga Trenerka', true);
insert into programs (id, gym_id, name, kind, is_active) values
  ('36363636-0000-0000-0000-00000000e001', '36363636-0000-0000-0000-00000000b001', 'pgTAP Personalni', 'personal', true),
  ('36363636-0000-0000-0000-00000000e002', '36363636-0000-0000-0000-00000000b001', 'pgTAP Grupni', 'group', true),
  ('36363636-0000-0000-0000-00000000e003', '36363636-0000-0000-0000-00000000b001', 'pgTAP Stari personalni', 'personal', false),
  ('36363636-0000-0000-0000-00000000e004', '36363636-0000-0000-0000-00000000b002', 'pgTAP Personalni', 'personal', true);
insert into trainer_programs (gym_id, trainer_id, program_id) values
  ('36363636-0000-0000-0000-00000000b001', '36363636-0000-0000-0000-00000000d001', '36363636-0000-0000-0000-00000000e001'),
  ('36363636-0000-0000-0000-00000000b001', '36363636-0000-0000-0000-00000000d001', '36363636-0000-0000-0000-00000000e002'),
  ('36363636-0000-0000-0000-00000000b001', '36363636-0000-0000-0000-00000000d002', '36363636-0000-0000-0000-00000000e001'),
  ('36363636-0000-0000-0000-00000000b001', '36363636-0000-0000-0000-00000000d003', '36363636-0000-0000-0000-00000000e001'),
  ('36363636-0000-0000-0000-00000000b001', '36363636-0000-0000-0000-00000000d004', '36363636-0000-0000-0000-00000000e002'),
  ('36363636-0000-0000-0000-00000000b001', '36363636-0000-0000-0000-00000000d005', '36363636-0000-0000-0000-00000000e003'),
  ('36363636-0000-0000-0000-00000000b002', '36363636-0000-0000-0000-00000000d006', '36363636-0000-0000-0000-00000000e004');

-- f001 Personalni, f002 Grupni; f003 the other gym's Personalni.
insert into plans (id, gym_id, name, kind, duration_value, duration_unit, price,
                   covers_gym, covers_group, covers_personal,
                   gym_visit_limit, group_session_limit, requires_trainer, sort_order) values
  ('36363636-0000-0000-0000-00000000f001', '36363636-0000-0000-0000-00000000b001', 'pgTAP Personalni',
   'personal', 1, 'month', null, false, false, true, null, null, true, 1),
  ('36363636-0000-0000-0000-00000000f002', '36363636-0000-0000-0000-00000000b001', 'pgTAP Grupni',
   'group', 1, 'month', 69, false, true, false, null, 12, true, 2),
  ('36363636-0000-0000-0000-00000000f003', '36363636-0000-0000-0000-00000000b002', 'pgTAP Personalni',
   'personal', 1, 'month', null, false, false, true, null, null, true, 1);

insert into members (id, gym_id, member_number, first_name, last_name, phone, email,
                     date_of_birth, created_by)
select ('36363636-0000-0000-0000-0000000200' || lpad(n::text, 2, '0'))::uuid,
       '36363636-0000-0000-0000-00000000b001', n, 'Clan', 'Broj' || n,
       '+3826736000' || lpad(n::text, 2, '0'), 'pr' || n || '@pgtap.invalid', '1990-01-01',
       '36363636-0000-0000-0000-00000000c002'
from generate_series(1, 8) as n;
insert into members (id, gym_id, member_number, first_name, last_name, phone, email,
                     date_of_birth, created_by) values
  ('36363636-0000-0000-0000-000000020099', '36363636-0000-0000-0000-00000000b002', 1, 'Drugi',
   'Clan', '+38267360099', 'pr99@pgtap.invalid', '1990-01-01',
   '36363636-0000-0000-0000-00000000c004');

-- 1 Personalni with Julija valid today (12 sessions), and the next one, starting after it;
-- 2 Personalni with Julija whose last day is today, every session used; 3 expired
-- yesterday; 4 voided; 5 anonymized; 6 Grupni with Julija; 7 Personalni with Stara;
-- 8 Personalni with Julija starting tomorrow. 99 is the other gym's.
insert into memberships (id, gym_id, member_id, plan_id, trainer_id, start_date, end_date,
                         start_reason, covers_gym, covers_group, covers_personal,
                         group_session_limit, personal_session_limit, is_backdated, created_by)
select v.id::uuid, v.gym::uuid, v.member::uuid, v.plan::uuid, v.trainer::uuid,
       d.today + v.s, d.today + v.e, 'fixture', false,
       v.plan = '36363636-0000-0000-0000-00000000f002',
       v.plan <> '36363636-0000-0000-0000-00000000f002',
       case when v.plan = '36363636-0000-0000-0000-00000000f002' then 12 end,
       v.sessions, true,
       case when v.gym = '36363636-0000-0000-0000-00000000b002'
            then '36363636-0000-0000-0000-00000000c004'
            else '36363636-0000-0000-0000-00000000c002' end::uuid
from (select gym_today('36363636-0000-0000-0000-00000000b001') as today) d,
     (values
       ('36363636-0000-0000-0000-000000030001', '36363636-0000-0000-0000-00000000b001',
        '36363636-0000-0000-0000-000000020001', '36363636-0000-0000-0000-00000000f001',
        '36363636-0000-0000-0000-00000000d001', -5, 25, 12),
       ('36363636-0000-0000-0000-000000030011', '36363636-0000-0000-0000-00000000b001',
        '36363636-0000-0000-0000-000000020001', '36363636-0000-0000-0000-00000000f001',
        '36363636-0000-0000-0000-00000000d001', 26, 56, 8),
       ('36363636-0000-0000-0000-000000030002', '36363636-0000-0000-0000-00000000b001',
        '36363636-0000-0000-0000-000000020002', '36363636-0000-0000-0000-00000000f001',
        '36363636-0000-0000-0000-00000000d001', -30, 0, 2),
       ('36363636-0000-0000-0000-000000030003', '36363636-0000-0000-0000-00000000b001',
        '36363636-0000-0000-0000-000000020003', '36363636-0000-0000-0000-00000000f001',
        '36363636-0000-0000-0000-00000000d001', -31, -1, 8),
       ('36363636-0000-0000-0000-000000030004', '36363636-0000-0000-0000-00000000b001',
        '36363636-0000-0000-0000-000000020004', '36363636-0000-0000-0000-00000000f001',
        '36363636-0000-0000-0000-00000000d001', -2, 28, 8),
       ('36363636-0000-0000-0000-000000030005', '36363636-0000-0000-0000-00000000b001',
        '36363636-0000-0000-0000-000000020005', '36363636-0000-0000-0000-00000000f001',
        '36363636-0000-0000-0000-00000000d001', -2, 28, 8),
       ('36363636-0000-0000-0000-000000030006', '36363636-0000-0000-0000-00000000b001',
        '36363636-0000-0000-0000-000000020006', '36363636-0000-0000-0000-00000000f002',
        '36363636-0000-0000-0000-00000000d001', -2, 28, null),
       ('36363636-0000-0000-0000-000000030007', '36363636-0000-0000-0000-00000000b001',
        '36363636-0000-0000-0000-000000020007', '36363636-0000-0000-0000-00000000f001',
        '36363636-0000-0000-0000-00000000d003', -2, 28, 8),
       ('36363636-0000-0000-0000-000000030008', '36363636-0000-0000-0000-00000000b001',
        '36363636-0000-0000-0000-000000020008', '36363636-0000-0000-0000-00000000f001',
        '36363636-0000-0000-0000-00000000d001', 1, 31, 8),
       ('36363636-0000-0000-0000-000000030099', '36363636-0000-0000-0000-00000000b002',
        '36363636-0000-0000-0000-000000020099', '36363636-0000-0000-0000-00000000f003',
        '36363636-0000-0000-0000-00000000d006', -2, 28, 8)
     ) as v(id, gym, member, plan, trainer, s, e, sessions);

-- Personalni is paid at the gym's fixed part (D-101): 80 € each, 100 € for member 1's next.
insert into payments (gym_id, kind, membership_id, member_id, plan_id, amount, method, paid_on,
                      is_backdated, created_by)
select ms.gym_id, 'membership', ms.id, ms.member_id, ms.plan_id,
       case when ms.id = '36363636-0000-0000-0000-000000030011' then 100
            when ms.plan_id = '36363636-0000-0000-0000-00000000f002' then 69
            else 80 end,
       'cash', least(ms.start_date, gym_today(ms.gym_id)), true, ms.created_by
from memberships ms
where ms.gym_id in ('36363636-0000-0000-0000-00000000b001',
                    '36363636-0000-0000-0000-00000000b002');

-- BR-095: member 4's sale is voided, membership and payment alike.
update memberships
set voided_at = now(), void_reason = 'test', voided_by = '36363636-0000-0000-0000-00000000c002'
where id = '36363636-0000-0000-0000-000000030004';
update payments
set voided_at = now(), void_reason = 'test', voided_by = '36363636-0000-0000-0000-00000000c002'
where membership_id = '36363636-0000-0000-0000-000000030004';
update members set is_anonymized = true where id = '36363636-0000-0000-0000-000000020005';

-- Member 1 trained twice with Julija on the current membership; member 2 used both sessions.
insert into visits (gym_id, member_id, membership_id, visit_type, trainer_id, is_unpaid,
                    checked_in_at, checked_out_at, checked_in_by)
select '36363636-0000-0000-0000-00000000b001', v.member::uuid, v.membership::uuid, 'personal',
       '36363636-0000-0000-0000-00000000d001', false,
       now() - make_interval(days => v.ago), now() - make_interval(days => v.ago)
         + interval '1 hour', '36363636-0000-0000-0000-00000000c001'
from (values
  ('36363636-0000-0000-0000-000000020001', '36363636-0000-0000-0000-000000030001', 3),
  ('36363636-0000-0000-0000-000000020001', '36363636-0000-0000-0000-000000030001', 1),
  ('36363636-0000-0000-0000-000000020002', '36363636-0000-0000-0000-000000030002', 9),
  ('36363636-0000-0000-0000-000000020002', '36363636-0000-0000-0000-000000030002', 2)
) as v(member, membership, ago);

-- The roster, as a receptionist (BR-027a) ----------------------------------------------
set local request.jwt.claims = '{"sub": "36363636-0000-0000-0000-00000000a001"}';
set local role authenticated;

select lives_ok($$select personal_roster()$$, 'D-105: a receptionist opens the personal roster');
select is(
  personal_roster() ->> 'today',
  gym_today('36363636-0000-0000-0000-00000000b001')::text,
  'BR-001: the roster is as of the gym''s today');

select is(
  (select array_agg(t ->> 'trainer_name' order by n)
   from json_array_elements(personal_roster() -> 'trainers') with ordinality as x(t, n)),
  array['pgTAP Julija', 'pgTAP Tamara'],
  'BR-023: every active trainer of an active personal program, by name, even with no members');

select is(
  (select string_agg(m ->> 'member_number', ',' order by n)
   from json_array_elements(personal_roster() -> 'members') with ordinality as x(m, n)),
  '1,1,2,8,7',
  'BR-027a: valid today or later, not expired, voided, anonymized or group; by trainer, then name');
select is(
  (select string_agg(m ->> 'membership_id', ',' order by n)
   from json_array_elements(personal_roster() -> 'members') with ordinality as x(m, n)
   where (m ->> 'member_number')::int = 1),
  '36363636-0000-0000-0000-000000030001,36363636-0000-0000-0000-000000030011',
  'BR-027a: one row per membership, the current one before the next');
select is(
  (select m ->> 'start_date' from json_array_elements(personal_roster() -> 'members') m
   where m ->> 'membership_id' = '36363636-0000-0000-0000-000000030008'),
  (gym_today('36363636-0000-0000-0000-00000000b001') + 1)::text,
  'BR-027a: a membership that starts tomorrow is listed with its first day');
select is(
  (select m ->> 'end_date' from json_array_elements(personal_roster() -> 'members') m
   where m ->> 'membership_id' = '36363636-0000-0000-0000-000000030002'),
  gym_today('36363636-0000-0000-0000-00000000b001')::text,
  'BR-051: a membership whose last day is today is still listed');

select is(
  (select m ->> 'paid_on' from json_array_elements(personal_roster() -> 'members') m
   where m ->> 'membership_id' = '36363636-0000-0000-0000-000000030001'),
  (gym_today('36363636-0000-0000-0000-00000000b001') - 5)::text,
  'BR-027a: the payment day of the membership');
select is(
  (select (m ->> 'personal_used')::int || '/' || (m ->> 'personal_session_limit')
   from json_array_elements(personal_roster() -> 'members') m
   where m ->> 'membership_id' = '36363636-0000-0000-0000-000000030001'),
  '2/12', 'BR-054: the personal visits counted on the membership, and its sessions');
select is(
  (select (m ->> 'personal_used')::int || '/' || (m ->> 'personal_session_limit')
   from json_array_elements(personal_roster() -> 'members') m
   where m ->> 'membership_id' = '36363636-0000-0000-0000-000000030011'),
  '0/8', 'BR-054: the next membership has used none yet');
select is(
  (select (m ->> 'personal_used')::int || '/' || (m ->> 'personal_session_limit')
   from json_array_elements(personal_roster() -> 'members') m
   where m ->> 'membership_id' = '36363636-0000-0000-0000-000000030002'),
  '2/2', 'BR-027a: used-up sessions do not remove a membership from the roster');
select is(
  (select m ->> 'trainer_name' from json_array_elements(personal_roster() -> 'members') m
   where m ->> 'membership_id' = '36363636-0000-0000-0000-000000030007'),
  'pgTAP Stara', 'BR-025: a trainer who is no longer active keeps their members');
select is(
  (select m ->> 'plan_name' from json_array_elements(personal_roster() -> 'members') m
   where m ->> 'membership_id' = '36363636-0000-0000-0000-000000030001'),
  'pgTAP Personalni', 'BR-027a: each row names its plan');

select ok(
  not exists (select 1 from json_array_elements(personal_roster() -> 'members') m
              where m::jsonb ? 'amount'),
  'BR-157: the personal roster carries no amount');
select throws_ok(
  $$select fin_roster_prices(array['36363636-0000-0000-0000-000000030001']::uuid[])$$,
  'P0001', 'E_FORBIDDEN', 'BR-157: a receptionist cannot read the amounts');
select is(
  (select string_agg(m ->> 'member_number', ',')
   from json_array_elements(trainer_roster() -> 'members') m),
  '6', 'BR-027: the Grupni roster still lists the group membership only');

-- The manager, another gym and a signed-in user who is not staff ---------------------------
reset role;
set local request.jwt.claims = '{"sub": "36363636-0000-0000-0000-00000000a003"}';
set local role authenticated;
select is(
  json_array_length(personal_roster() -> 'members'), 5, 'D-105: a manager opens the roster');

reset role;
set local request.jwt.claims = '{"sub": "36363636-0000-0000-0000-00000000a004"}';
set local role authenticated;
select is(
  (select string_agg(m ->> 'membership_id', ',')
   from json_array_elements(personal_roster() -> 'members') m)
  || '|' ||
  (select string_agg(t ->> 'trainer_id', ',')
   from json_array_elements(personal_roster() -> 'trainers') t),
  '36363636-0000-0000-0000-000000030099|36363636-0000-0000-0000-00000000d006',
  'Doc 04 §1: another gym''s staff see only their own gym');
select is(
  json_array_length(fin_roster_prices(array['36363636-0000-0000-0000-000000030001']::uuid[])),
  0, 'Doc 04 §1: another gym''s owner gets no amount of this gym');

reset role;
set local request.jwt.claims = '{"sub": "36363636-0000-0000-0000-00000000a005"}';
set local role authenticated;
select throws_ok(
  $$select personal_roster()$$, 'P0001', 'E_NOT_STAFF',
  'Doc 08 §5: a signed-in user who is not staff gets nothing');

-- The owner's amounts ------------------------------------------------------------------------
reset role;
set local request.jwt.claims = '{"sub": "36363636-0000-0000-0000-00000000a002"}';
set local role authenticated;
select is(
  (select string_agg(p ->> 'amount', ',' order by p ->> 'membership_id')
   from json_array_elements(fin_roster_prices(array[
     '36363636-0000-0000-0000-000000030001',
     '36363636-0000-0000-0000-000000030011',
     '36363636-0000-0000-0000-000000030004']::uuid[])) p),
  '80.00,100.00',
  'BR-027a: the owner gets each personal amount (the gym''s fixed part), a voided one excepted');
reset role;

-- Privileges ---------------------------------------------------------------------------------
select ok(not has_function_privilege('anon', 'personal_roster()', 'execute'),
  'Doc 08 §4: anon cannot read the personal roster');
select ok(has_function_privilege('authenticated', 'personal_roster()', 'execute'),
  'Doc 08 §4: signed-in staff can call it, and current_staff() checks the rest');
select is(
  (select provolatile::text || prosecdef::text from pg_proc
   where oid = 'personal_roster()'::regprocedure),
  'strue', 'Doc 08 §4: the roster only reads (stable) and is security definer');

select * from finish();
