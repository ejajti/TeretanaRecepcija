-- D-111 (migration 0064, BR-055a): the owner and the admin change the sessions left on a
-- membership from S-07 [Izmijeni termine]. The limit becomes the sessions used plus the
-- number left; the dates stay. Added sessions first link the member's unlinked unpaid
-- visits of that type from the membership's days, oldest first. Managers and
-- receptionists are refused (P-24b), and the change is audited (BR-096).
select plan(29);

-- Fixtures --------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('64646464-0000-0000-0000-00000000a001', null),
  ('64646464-0000-0000-0000-00000000a002', null),
  ('64646464-0000-0000-0000-00000000a003', null),
  ('64646464-0000-0000-0000-00000000a004', null);
insert into gyms (id, name, timezone)
values ('64646464-0000-0000-0000-00000000b001', 'pgTAP Termini', 'Europe/Podgorica');
insert into gym_settings (gym_id) values ('64646464-0000-0000-0000-00000000b001');
insert into staff (id, gym_id, user_id, role, full_name, email, username) values
  ('64646464-0000-0000-0000-00000000c001', '64646464-0000-0000-0000-00000000b001',
   '64646464-0000-0000-0000-00000000a001', 'owner', 'pgTAP Vlasnik', null, 'pgtap.st.vlasnik'),
  ('64646464-0000-0000-0000-00000000c002', '64646464-0000-0000-0000-00000000b001',
   '64646464-0000-0000-0000-00000000a002', 'admin', 'pgTAP Admin', 'pgtap.st.admin@example.com',
   null),
  ('64646464-0000-0000-0000-00000000c003', '64646464-0000-0000-0000-00000000b001',
   '64646464-0000-0000-0000-00000000a003', 'manager', 'pgTAP Menadžer', null, 'pgtap.st.menadzer'),
  ('64646464-0000-0000-0000-00000000c004', '64646464-0000-0000-0000-00000000b001',
   '64646464-0000-0000-0000-00000000a004', 'receptionist', 'pgTAP Recepcija', null,
   'pgtap.st.recepcija');

-- A group visit names its trainer (visits check).
insert into trainers (id, gym_id, full_name) values
  ('64646464-0000-0000-0000-00000000d001', '64646464-0000-0000-0000-00000000b001', 'pgTAP Milena');

insert into plans (id, gym_id, name, kind, duration_value, duration_unit, price,
                   covers_gym, covers_group, covers_personal,
                   gym_visit_limit, group_session_limit, requires_trainer) values
  ('64646464-0000-0000-0000-00000000f001', '64646464-0000-0000-0000-00000000b001',
   'pgTAP Mjesečna 3 termina', 'gym', 1, 'month', 39, true, false, false, 3, null, false),
  ('64646464-0000-0000-0000-00000000f002', '64646464-0000-0000-0000-00000000b001',
   'pgTAP G+T', 'combo', 1, 'month', 99, true, true, false, null, 12, true),
  ('64646464-0000-0000-0000-00000000f003', '64646464-0000-0000-0000-00000000b001',
   'pgTAP Personalni', 'personal', 1, 'month', null, false, false, true, null, null, true);

insert into members (id, gym_id, member_number, first_name, last_name, phone, email,
                     date_of_birth, created_by)
select ('64646464-0000-0000-0000-0000000200' || lpad(n::text, 2, '0'))::uuid,
       '64646464-0000-0000-0000-00000000b001', n, 'Član', 'Broj ' || n,
       '+3826764000' || lpad(n::text, 2, '0'), 'st' || n || '@pgtap.invalid', '1990-01-01',
       '64646464-0000-0000-0000-00000000c001'
from generate_series(1, 5) as n;

-- X is gym today. Member 1: Mjesečna 3 termina X-20..X+10 (3 used); 2: G+T, 2 group
-- sessions used; 3: Personalni with 10, none used; 4: Mjesečna 3 termina that ended
-- yesterday, all 3 used; 5: Mjesečna 3 termina, all used, paused X-6..X-5; 6 (member 1):
-- a voided one.
create temporary table clock as
select gym_today('64646464-0000-0000-0000-00000000b001') as x;
grant select on clock to authenticated;
insert into memberships (id, gym_id, member_id, plan_id, start_date, end_date, start_reason,
                         covers_gym, covers_group, covers_personal, gym_visit_limit,
                         group_session_limit, personal_session_limit, is_backdated,
                         created_by, voided_at, voided_by, void_reason)
select ('64646464-0000-0000-0000-0000000300' || v.id)::uuid,
       '64646464-0000-0000-0000-00000000b001',
       ('64646464-0000-0000-0000-0000000200' || v.member)::uuid,
       ('64646464-0000-0000-0000-00000000f00' || v.plan)::uuid,
       c.x + v.s, c.x + v.e, 'fixture', v.g, v.gr, v.p, v.gl, v.grl, v.pl, true,
       '64646464-0000-0000-0000-00000000c001',
       case when v.voided then now() end,
       case when v.voided then '64646464-0000-0000-0000-00000000c001'::uuid end,
       case when v.voided then 'pgTAP poništeno' end
from clock c, (values
  ('01', '01', 1, -20, 10, true, false, false, 3::smallint, null::smallint, null::smallint, false),
  ('02', '02', 2, -10, 20, true, true, false, null, 12, null, false),
  ('03', '03', 3, -5, 25, false, false, true, null, null, 10, false),
  ('04', '04', 1, -31, -1, true, false, false, 3, null, null, false),
  ('05', '05', 1, -20, 10, true, false, false, 3, null, null, false),
  ('06', '01', 1, -20, 10, true, false, false, 3, null, null, true)
) as v(id, member, plan, s, e, g, gr, p, gl, grl, pl, voided);
insert into membership_pauses (gym_id, membership_id, paused_from, paused_until, created_by)
select '64646464-0000-0000-0000-00000000b001', '64646464-0000-0000-0000-000000030005',
       x - 6, x - 5, '64646464-0000-0000-0000-00000000c001'
from clock;

-- Visits at 10:00 local. Linked ones use sessions; unlinked unpaid ones are what the
-- badge counts (US-10.1).
insert into visits (id, gym_id, member_id, membership_id, visit_type, trainer_id, is_unpaid,
                    checked_in_at, checked_out_at, checked_in_by, is_backdated)
select ('64646464-0000-0000-0000-0000000400' || v.id)::uuid,
       '64646464-0000-0000-0000-00000000b001',
       ('64646464-0000-0000-0000-0000000200' || v.member)::uuid,
       case when v.ms is not null then ('64646464-0000-0000-0000-0000000300' || v.ms)::uuid end,
       v.type::visit_type,
       case when v.type <> 'gym' then '64646464-0000-0000-0000-00000000d001'::uuid end,
       v.ms is null,
       (c.x + v.day + time '10:00') at time zone 'Europe/Podgorica',
       (c.x + v.day + time '11:00') at time zone 'Europe/Podgorica',
       '64646464-0000-0000-0000-00000000c004', false
from clock c, (values
  -- Member 1: 3 used, then unpaid gym visits on X-5 and X-3, one before the start
  -- (X-25) and an unpaid group visit (X-4).
  ('11', '01', '01', 'gym', -15), ('12', '01', '01', 'gym', -12), ('13', '01', '01', 'gym', -9),
  ('14', '01', null, 'gym', -5), ('15', '01', null, 'gym', -3),
  ('16', '01', null, 'gym', -25), ('17', '01', null, 'group', -4),
  -- Member 2: two group sessions used.
  ('21', '02', '02', 'group', -8), ('22', '02', '02', 'group', -6),
  -- Member 4: 3 used, then an unpaid gym visit on X-2, inside the expired membership.
  ('41', '04', '04', 'gym', -20), ('42', '04', '04', 'gym', -15), ('43', '04', '04', 'gym', -10),
  ('44', '04', null, 'gym', -2),
  -- Member 5: 3 used, then an unpaid gym visit on the paused day X-6.
  ('51', '05', '05', 'gym', -15), ('52', '05', '05', 'gym', -12), ('53', '05', '05', 'gym', -9),
  ('54', '05', null, 'gym', -6)
) as v(id, member, ms, type, day);

set local role authenticated;

-- Owner ---------------------------------------------------------------------------------
set local request.jwt.claims = '{"sub": "64646464-0000-0000-0000-00000000a001"}';

select is(
  (select (r ->> 'linked') || '|' || (r ->> 'unpaid_count')
   from (select set_membership_sessions('64646464-0000-0000-0000-000000030001', 1) as r) s),
  '1|3',
  'D-111: one session more links the oldest unpaid gym visit of its days; three stay unpaid');
select is(
  (select gym_visit_limit::text || '|' || start_date || '|' || end_date
   from memberships where id = '64646464-0000-0000-0000-000000030001'),
  '4|' || ((select x from clock) - 20) || '|' || ((select x from clock) + 10),
  'D-111: the limit is the 3 used plus 1; the dates do not change');
select is(
  (select membership_id::text || '|' || is_unpaid
   from visits where id = '64646464-0000-0000-0000-000000040014'),
  '64646464-0000-0000-0000-000000030001|true',
  'D-111: the X-5 visit is linked; is_unpaid stays true as history (D-106)');
select is(
  (select count(*)::int from visits
   where id in ('64646464-0000-0000-0000-000000040015', '64646464-0000-0000-0000-000000040016',
                '64646464-0000-0000-0000-000000040017')
     and membership_id is null),
  3,
  'D-111: the later one (no session left), one before the start and the group visit stay unlinked');
select is(membership_status('64646464-0000-0000-0000-000000030001', (select x from clock)),
  'used_up', 'BR-054: with the new session used by the linked visit, it is used up');

-- Admin: same rights as the owner (D-58).
set local request.jwt.claims = '{"sub": "64646464-0000-0000-0000-00000000a002"}';
select is(
  (select (r ->> 'linked') || '|' || (r ->> 'unpaid_count')
   from (select set_membership_sessions('64646464-0000-0000-0000-000000030001', 2) as r) s),
  '1|2',
  'D-111: the admin adds two; the X-3 visit takes one of them');
select is(
  (select gym_visit_limit - membership_used(id, 'gym') from memberships
   where id = '64646464-0000-0000-0000-000000030001'),
  1, 'BR-055: one session is left, as typed less the one the linked visit used');
select is(membership_status('64646464-0000-0000-0000-000000030001', (select x from clock)),
  'active', 'BR-054: with a session left it is active again');

-- Fewer sessions link nothing.
set local request.jwt.claims = '{"sub": "64646464-0000-0000-0000-00000000a001"}';
select is(
  (select (r ->> 'linked')
   from (select set_membership_sessions('64646464-0000-0000-0000-000000030001', 0) as r) s),
  '0', 'D-111: taking the last session away links nothing');
select is(
  (select gym_visit_limit from memberships where id = '64646464-0000-0000-0000-000000030001'),
  5::smallint, 'D-111: 0 left means the limit equals the 5 used');

-- G+T: the group sessions only; the gym part is Neograničeno.
select is(
  (select set_membership_sessions('64646464-0000-0000-0000-000000030002',
     p_group_left => 5) ->> 'linked'),
  '0', 'D-111: G+T gets group sessions; with no unpaid visit nothing is linked');
select is(
  (select group_session_limit::text || '|' || (gym_visit_limit is null) from memberships
   where id = '64646464-0000-0000-0000-000000030002'),
  '7|true', 'D-111: with 2 group sessions used and 5 left it has 7; the gym part stays unlimited');
select throws_ok(
  $$select set_membership_sessions('64646464-0000-0000-0000-000000030002', p_gym_left => 3)$$,
  'P0001', 'E_VALIDATION', 'D-111: an unlimited type has no sessions to change');

-- Personalni: 0 to 99, at least 1 while none is used.
select throws_ok(
  $$select set_membership_sessions('64646464-0000-0000-0000-000000030003', p_personal_left => 0)$$,
  'P0001', 'E_SESSIONS_INVALID', 'D-111: a membership never holds 0 sessions in total');
select throws_ok(
  $$select set_membership_sessions('64646464-0000-0000-0000-000000030003', p_personal_left => 100)$$,
  'P0001', 'E_SESSIONS_INVALID', 'D-111: at most 99 left');
select throws_ok(
  $$select set_membership_sessions('64646464-0000-0000-0000-000000030003', p_personal_left => -1)$$,
  'P0001', 'E_SESSIONS_INVALID', 'D-111: never fewer than 0 left');
select lives_ok(
  $$select set_membership_sessions('64646464-0000-0000-0000-000000030003', p_personal_left => 60)$$,
  'D-111: more than the 50 a sale allows (BR-059 limits only the sale)');
select is(
  (select personal_session_limit from memberships
   where id = '64646464-0000-0000-0000-000000030003'),
  60::smallint, 'D-111: the Personalni now has 60 sessions');

-- Expired: its own days' unpaid visit is linked.
select is(
  (select (r ->> 'linked')
   from (select set_membership_sessions('64646464-0000-0000-0000-000000030004', 1) as r) s),
  '1', 'D-111: an expired membership too; the visit inside its days takes the session');
select is(
  (select membership_id from visits where id = '64646464-0000-0000-0000-000000040044'),
  '64646464-0000-0000-0000-000000030004'::uuid, 'D-111: the X-2 visit is now paid by it');

-- A paused day covers nothing (BR-053), so its visit stays unpaid.
select is(
  (select (r ->> 'linked')
   from (select set_membership_sessions('64646464-0000-0000-0000-000000030005', 1) as r) s),
  '0', 'D-111: a visit on a paused day is not linked');

-- Refusals ---------------------------------------------------------------------------------
select throws_ok(
  $$select set_membership_sessions('64646464-0000-0000-0000-000000030006', 1)$$,
  'P0001', 'E_VALIDATION', 'D-111: not on a voided membership');
select throws_ok(
  $$select set_membership_sessions('64646464-0000-0000-0000-000000030001')$$,
  'P0001', 'E_VALIDATION', 'D-111: at least one type must be given');
select throws_ok(
  $$select set_membership_sessions('64646464-0000-0000-0000-0000000309ff', 1)$$,
  'P0001', 'E_FORBIDDEN', 'D-111: only a membership of the caller''s gym');

set local request.jwt.claims = '{"sub": "64646464-0000-0000-0000-00000000a003"}';
select throws_ok(
  $$select set_membership_sessions('64646464-0000-0000-0000-000000030001', 3)$$,
  'P0001', 'E_FORBIDDEN', 'P-24b: a manager may not change sessions');
set local request.jwt.claims = '{"sub": "64646464-0000-0000-0000-00000000a004"}';
select throws_ok(
  $$select set_membership_sessions('64646464-0000-0000-0000-000000030001', 3)$$,
  'P0001', 'E_FORBIDDEN', 'P-24b: a receptionist may not change sessions');

-- BR-096 and grants ----------------------------------------------------------------------
reset role;
select is(
  (select count(*)::int from audit_log
   where table_name = 'memberships' and row_id = '64646464-0000-0000-0000-000000030001'
     and action = 'update' and changed_by = '64646464-0000-0000-0000-00000000c001'
     and old_data ->> 'gym_visit_limit' = '3' and new_data ->> 'gym_visit_limit' = '4'),
  1, 'BR-096: the change is in the audit log with the old and new limit and who made it');
select ok(
  not has_function_privilege('anon',
    'set_membership_sessions(uuid, integer, integer, integer)', 'execute'),
  'D-111: not callable without signing in');
select throws_ok(
  $$update memberships set personal_session_limit = 0
    where id = '64646464-0000-0000-0000-000000030003'$$,
  '23514', null, 'D-111: the table still refuses a limit below 1');

select * from finish();
