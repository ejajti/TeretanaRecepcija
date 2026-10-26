-- D-107 (migration 0060, BR-052 step 1): a comparable membership whose shared limited
-- types are all used up counts as ending on the day of its last session, so a sale made
-- while it is still in its dates starts from the first unpaid visit after that day (and
-- links it) or today. A membership with something left still holds the sale back.
select plan(9);

-- Fixtures --------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('60606060-0000-0000-0000-00000000a001', null),
  ('60606060-0000-0000-0000-00000000a002', null);
insert into gyms (id, name, timezone)
values ('60606060-0000-0000-0000-00000000b001', 'pgTAP Potroseni termini', 'Europe/Podgorica');
insert into gym_settings (gym_id) values ('60606060-0000-0000-0000-00000000b001');
insert into staff (id, gym_id, user_id, role, full_name, username) values
  ('60606060-0000-0000-0000-00000000c001', '60606060-0000-0000-0000-00000000b001',
   '60606060-0000-0000-0000-00000000a001', 'receptionist', 'pgTAP Recepcija', 'pgtap.pt.recepcija'),
  ('60606060-0000-0000-0000-00000000c002', '60606060-0000-0000-0000-00000000b001',
   '60606060-0000-0000-0000-00000000a002', 'owner', 'pgTAP Vlasnik', 'pgtap.pt.vlasnik');
insert into shifts (id, gym_id, staff_id)
values ('60606060-0000-0000-0000-00000000c101', '60606060-0000-0000-0000-00000000b001',
        '60606060-0000-0000-0000-00000000c001');
insert into trainers (id, gym_id, full_name) values
  ('60606060-0000-0000-0000-00000000d001', '60606060-0000-0000-0000-00000000b001', 'pgTAP Milena');
insert into trainer_finance (trainer_id, gym_id)
values ('60606060-0000-0000-0000-00000000d001', '60606060-0000-0000-0000-00000000b001');
insert into programs (id, gym_id, name, kind) values
  ('60606060-0000-0000-0000-00000000e001', '60606060-0000-0000-0000-00000000b001', 'pgTAP Grupni', 'group');
insert into trainer_programs (gym_id, trainer_id, program_id) values
  ('60606060-0000-0000-0000-00000000b001', '60606060-0000-0000-0000-00000000d001', '60606060-0000-0000-0000-00000000e001');

-- Plans: f001 Mjesečna 12 termina, f002 Mjesečna (unlimited), f003 Grupni, f004 G+T.
insert into plans (id, gym_id, name, kind, duration_value, duration_unit, price,
                   covers_gym, covers_group, covers_personal,
                   gym_visit_limit, group_session_limit, requires_trainer) values
  ('60606060-0000-0000-0000-00000000f001', '60606060-0000-0000-0000-00000000b001', 'pgTAP 12 termina',
   'gym', 1, 'month', 59, true, false, false, 12, null, false),
  ('60606060-0000-0000-0000-00000000f002', '60606060-0000-0000-0000-00000000b001', 'pgTAP Mjesečna',
   'gym', 1, 'month', 79, true, false, false, null, null, false),
  ('60606060-0000-0000-0000-00000000f003', '60606060-0000-0000-0000-00000000b001', 'pgTAP Grupni',
   'group', 1, 'month', 69, false, true, false, null, 12, true),
  ('60606060-0000-0000-0000-00000000f004', '60606060-0000-0000-0000-00000000b001', 'pgTAP G+T',
   'combo', 1, 'month', 99, true, true, false, null, 12, true);
insert into plan_finance (plan_id, gym_id)
select id, gym_id from plans where gym_id = '60606060-0000-0000-0000-00000000b001';

insert into members (id, gym_id, member_number, first_name, last_name, phone, email,
                     date_of_birth, created_by)
select ('60606060-0000-0000-0000-0000000200' || lpad(n::text, 2, '0'))::uuid,
       '60606060-0000-0000-0000-00000000b001', n, 'Član', 'Broj ' || n,
       '+3826760000' || lpad(n::text, 2, '0'), 'pt' || n || '@pgtap.invalid', '1990-01-01',
       '60606060-0000-0000-0000-00000000c002'
from generate_series(1, 5) as n;

-- All memberships run from 20 days ago to 10 days ahead.
-- 1: 12 termina, all used, and an unpaid visit today.  2: 12 termina, all used, nothing
-- unpaid.  3: 12 termina with 11 used.  4: unlimited Mjesečna.  5: G+T with every group
-- session used (gym unlimited).
insert into memberships (id, gym_id, member_id, plan_id, trainer_id, start_date, end_date,
                         start_reason, covers_gym, covers_group, covers_personal,
                         gym_visit_limit, group_session_limit, is_backdated, created_by)
select v.id::uuid, '60606060-0000-0000-0000-00000000b001',
       ('60606060-0000-0000-0000-0000000200' || v.member)::uuid,
       ('60606060-0000-0000-0000-00000000' || v.plan)::uuid,
       v.trainer::uuid, gym_today('60606060-0000-0000-0000-00000000b001') - 20,
       gym_today('60606060-0000-0000-0000-00000000b001') + 10, 'fixture',
       v.g, v.gr, false, v.gl, v.grl, true, '60606060-0000-0000-0000-00000000c002'
from (values
  ('60606060-0000-0000-0000-000000030001', '01', 'f001', null, true, false, 12::smallint, null::smallint),
  ('60606060-0000-0000-0000-000000030002', '02', 'f001', null, true, false, 12, null),
  ('60606060-0000-0000-0000-000000030003', '03', 'f001', null, true, false, 12, null),
  ('60606060-0000-0000-0000-000000030004', '04', 'f002', null, true, false, null, null),
  ('60606060-0000-0000-0000-000000030005', '05', 'f004', '60606060-0000-0000-0000-00000000d001', true, true, null, 12)
) as v(id, member, plan, trainer, g, gr, gl, grl);

-- The sessions used, the last one three days ago (12, 12, 11, 5 and 12 group).
insert into visits (gym_id, member_id, membership_id, visit_type, trainer_id, checked_in_at,
                    checked_out_at, checked_in_by, is_backdated)
select '60606060-0000-0000-0000-00000000b001',
       ('60606060-0000-0000-0000-0000000200' || u.member)::uuid,
       ('60606060-0000-0000-0000-0000000300' || u.member)::uuid, u.kind::visit_type,
       case when u.kind = 'group' then '60606060-0000-0000-0000-00000000d001'::uuid end,
       now() - make_interval(days => 2 + n), now() - make_interval(days => 2 + n) + interval '1 hour',
       '60606060-0000-0000-0000-00000000c001', true
from (values ('01', 'gym', 12), ('02', 'gym', 12), ('03', 'gym', 11), ('04', 'gym', 5),
             ('05', 'group', 12)) as u(member, kind, used),
     generate_series(1, u.used) as n;
-- Member 1 comes today with nothing left: an unpaid gym visit.
insert into visits (gym_id, member_id, visit_type, is_unpaid, checked_in_at, checked_in_by,
                    is_backdated)
values ('60606060-0000-0000-0000-00000000b001', '60606060-0000-0000-0000-000000020001', 'gym',
        true, now(), '60606060-0000-0000-0000-00000000c001', true);

set local request.jwt.claims = '{"sub": "60606060-0000-0000-0000-00000000a001"}';
set local role authenticated;

select is(
  (select (s.start_date = gym_today('60606060-0000-0000-0000-00000000b001')) || '|' || s.reason
          || '|' || cardinality(s.visit_ids)
   from calc_membership_start('60606060-0000-0000-0000-000000020001',
          '60606060-0000-0000-0000-00000000f001') s),
  'true|Počinje od prvog neplaćenog dolaska ' || to_char(gym_today('60606060-0000-0000-0000-00000000b001'), 'DD.MM.YYYY') || '|1',
  'D-107: sessions used up, the next one starts on today''s unpaid visit and takes it');
select is(
  (sell_membership('60606060-0000-0000-0000-000000020001', '60606060-0000-0000-0000-00000000f001',
     null, null, null, 'cash') ->> 'linked_visits')::int,
  1, 'D-107: the sale links it');
select is(
  (select count(*)::int from visits
   where member_id = '60606060-0000-0000-0000-000000020001' and is_unpaid and membership_id is null),
  0, 'US-10.1: so no unpaid visit is left on the day the member paid');

select is(
  (select (s.start_date = gym_today('60606060-0000-0000-0000-00000000b001')) || '|' || s.reason
   from calc_membership_start('60606060-0000-0000-0000-000000020002',
          '60606060-0000-0000-0000-00000000f001') s),
  'true|Počinje danas', 'D-107: sessions used up and nothing unpaid: it starts today');
select is(
  (select (s.start_date = gym_today('60606060-0000-0000-0000-00000000b001') + 11)::text
   from calc_membership_start('60606060-0000-0000-0000-000000020003',
          '60606060-0000-0000-0000-00000000f001') s),
  'true', 'BR-052 step 1: one session left, it still continues after the last day');
select is(
  (select (s.start_date = gym_today('60606060-0000-0000-0000-00000000b001') + 11)::text
   from calc_membership_start('60606060-0000-0000-0000-000000020004',
          '60606060-0000-0000-0000-00000000f002') s),
  'true', 'BR-052 step 1: an unlimited membership is never used up');
select is(
  (select (s.start_date = gym_today('60606060-0000-0000-0000-00000000b001'))::text
   from calc_membership_start('60606060-0000-0000-0000-000000020005',
          '60606060-0000-0000-0000-00000000f003') s),
  'true', 'D-107: a Grupni after a G+T with every group session used starts today');
select is(
  (select (s.start_date = gym_today('60606060-0000-0000-0000-00000000b001') + 11)::text
   from calc_membership_start('60606060-0000-0000-0000-000000020005',
          '60606060-0000-0000-0000-00000000f004') s),
  'true', 'D-107: a G+T after it continues, since its gym part is not used up');
select is(
  (select s.reason
   from calc_membership_start('60606060-0000-0000-0000-000000020002',
          '60606060-0000-0000-0000-00000000f002') s),
  'Počinje danas', 'D-107: any gym plan after a used-up 12 termina starts today');

reset role;
select * from finish();
