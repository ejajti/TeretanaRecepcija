-- D-106: the visits recorded before migration 0058 that its rules record differently,
-- found on the production gym on 26.10.2026. Agreed with Mihajlo the same day.
--
-- Recorded as unpaid gym visits, now the group visits they were, linked to the
-- membership the member bought (D-106 point 1; point 2 for #95):
--   #10  20.10.2026 18:00  Milena, Tue 18:00 class, Grupni 20.10–20.11
--   #14  06.10.2026 17:57  Milena, Tue 18:00 class, Grupni moved to 06.10–06.11 (below)
--   #14  08.10.2026 17:54  Milena, Thu 18:00 class, the same Grupni
--   #95  14.10.2026 17:07  Tamara, Wed 19:00 class, the Grupni sold at 17:07 (registration)
-- #14's Grupni was sold on 08.10 with "Počinje danas" (08.10–08.11). BR-052 step 2 now
-- starts it from her first unpaid visit: 06.10–06.11. Her payment is not touched.
--
-- Recorded by "Prijavi odmah" on a membership that starts the next day, so under D-106
-- point 2 no visit is recorded. These two rows are deleted:
--   #72  11.10.2026 16:59  visit aeded9ba-994a-45cf-a0fa-ae443eb84edc, Grupni from 12.10
--   #114 18.10.2026 18:05  visit ef4adeda-e04d-4306-8162-33e51f477fed, Dvonedeljna from 19.10
--
-- Every row must still be exactly as found on 26.10.2026; if one differs, the migration
-- stops and nothing changes. A database without these rows (a dev project) is skipped.
-- No payment is changed.

do $$
declare
  v_found int;
  v_ok    int;
begin
  select count(*) into v_found
  from visits
  where id in (
    'bfee4072-91e7-4ea9-a25c-fc4cd9b80f9c', 'e2f4bbd7-01d1-44af-bb36-e3540554ddfa',
    'c984e94b-5d04-40a0-b945-de3cc25440d2', '0e5e101e-1a40-49ba-a5a0-2ce733f271b4',
    'aeded9ba-994a-45cf-a0fa-ae443eb84edc', 'ef4adeda-e04d-4306-8162-33e51f477fed'
  );
  if v_found = 0 then
    raise notice 'D-106 repair: the production visits are not in this database, skipped';
    return;
  end if;

  -- The six visits: still unlinked unpaid gym visits of these members, at these times.
  select count(*) into v_ok
  from visits v
  join members m on m.id = v.member_id
  join (values
    ('bfee4072-91e7-4ea9-a25c-fc4cd9b80f9c'::uuid, 10, '2026-10-20 18:00'),
    ('e2f4bbd7-01d1-44af-bb36-e3540554ddfa'::uuid, 14, '2026-10-06 17:57'),
    ('c984e94b-5d04-40a0-b945-de3cc25440d2'::uuid, 14, '2026-10-08 17:54'),
    ('0e5e101e-1a40-49ba-a5a0-2ce733f271b4'::uuid, 95, '2026-10-14 17:07'),
    ('aeded9ba-994a-45cf-a0fa-ae443eb84edc'::uuid, 72, '2026-10-11 16:59'),
    ('ef4adeda-e04d-4306-8162-33e51f477fed'::uuid, 114, '2026-10-18 18:05')
  ) as e(id, member_number, local_time) on e.id = v.id
  where m.member_number = e.member_number
    and to_char(v.checked_in_at at time zone 'Europe/Podgorica', 'YYYY-MM-DD HH24:MI') = e.local_time
    and v.visit_type = 'gym' and v.is_unpaid and v.membership_id is null
    and v.trainer_id is null and v.class_slot_id is null and v.checked_out_at is not null;
  if v_ok <> 6 then
    raise exception 'D-106 repair: % of the 6 visits are as found on 26.10.2026', v_ok;
  end if;

  -- The three memberships the visits join, not voided, with their sold dates and use.
  select count(*) into v_ok
  from memberships ms
  join (values
    ('27639e7c-c3fd-413f-8a51-e3710524969f'::uuid, date '2026-10-20', date '2026-11-20',
     '360bd31a-935e-4258-8fa3-86e58c85eff4'::uuid, 1),
    ('75230293-002e-4ecb-8c60-4bead00e45cc'::uuid, date '2026-10-08', date '2026-11-08',
     '360bd31a-935e-4258-8fa3-86e58c85eff4'::uuid, 6),
    ('b952f010-d61c-461d-9fb2-9640f09d2213'::uuid, date '2026-10-14', date '2026-11-14',
     '3b5342c5-e44d-4397-99e6-cd63ad3e2c7a'::uuid, 4)
  ) as e(id, start_date, end_date, trainer_id, used) on e.id = ms.id
  where ms.voided_at is null
    and ms.start_date = e.start_date and ms.end_date = e.end_date
    and ms.trainer_id = e.trainer_id
    and ms.covers_group and not ms.covers_gym and not ms.covers_personal
    and ms.group_session_limit = 12
    and (select count(*) from visits x where x.membership_id = ms.id) = e.used
    and not exists (select 1 from membership_pauses mp where mp.membership_id = ms.id);
  if v_ok <> 3 then
    raise exception 'D-106 repair: % of the 3 memberships are as found on 26.10.2026', v_ok;
  end if;

  -- The classes the visits were at: active, of their trainer, on that weekday and time.
  select count(*) into v_ok
  from class_slots cs
  join (values
    ('11afbc61-545a-4a96-8a0d-e37b695ef652'::uuid, '360bd31a-935e-4258-8fa3-86e58c85eff4'::uuid, 2, time '18:00'),
    ('34850235-ecf1-4fab-acba-80796f5eb954'::uuid, '360bd31a-935e-4258-8fa3-86e58c85eff4'::uuid, 4, time '18:00'),
    ('7da5590d-423e-4053-8593-587ec813bf16'::uuid, '3b5342c5-e44d-4397-99e6-cd63ad3e2c7a'::uuid, 3, time '19:00')
  ) as e(id, trainer_id, weekday, starts_at) on e.id = cs.id
  where cs.trainer_id = e.trainer_id and cs.weekday = e.weekday and cs.starts_at = e.starts_at;
  if v_ok <> 3 then
    raise exception 'D-106 repair: % of the 3 class slots are as found on 26.10.2026', v_ok;
  end if;

  -- #14: BR-052 step 2, from her first unpaid visit (the audit trigger records it).
  update memberships
  set start_date = date '2026-10-06',
      end_date = membership_end_date(date '2026-10-06', p.duration_value, p.duration_unit),
      start_reason = 'Počinje od prvog neplaćenog dolaska 06.10.2026'
  from plans p
  where memberships.id = '75230293-002e-4ecb-8c60-4bead00e45cc' and p.id = memberships.plan_id;

  -- The group visits, linked. is_unpaid stays true as history, as BR-052 links visits.
  update visits v
  set visit_type = 'group', trainer_id = e.trainer_id, class_slot_id = e.slot_id,
      membership_id = e.membership_id
  from (values
    ('bfee4072-91e7-4ea9-a25c-fc4cd9b80f9c'::uuid, '360bd31a-935e-4258-8fa3-86e58c85eff4'::uuid,
     '11afbc61-545a-4a96-8a0d-e37b695ef652'::uuid, '27639e7c-c3fd-413f-8a51-e3710524969f'::uuid),
    ('e2f4bbd7-01d1-44af-bb36-e3540554ddfa'::uuid, '360bd31a-935e-4258-8fa3-86e58c85eff4'::uuid,
     '11afbc61-545a-4a96-8a0d-e37b695ef652'::uuid, '75230293-002e-4ecb-8c60-4bead00e45cc'::uuid),
    ('c984e94b-5d04-40a0-b945-de3cc25440d2'::uuid, '360bd31a-935e-4258-8fa3-86e58c85eff4'::uuid,
     '34850235-ecf1-4fab-acba-80796f5eb954'::uuid, '75230293-002e-4ecb-8c60-4bead00e45cc'::uuid),
    ('0e5e101e-1a40-49ba-a5a0-2ce733f271b4'::uuid, '3b5342c5-e44d-4397-99e6-cd63ad3e2c7a'::uuid,
     '7da5590d-423e-4053-8593-587ec813bf16'::uuid, 'b952f010-d61c-461d-9fb2-9640f09d2213'::uuid)
  ) as e(id, trainer_id, slot_id, membership_id)
  where v.id = e.id;

  delete from visits
  where id in ('aeded9ba-994a-45cf-a0fa-ae443eb84edc', 'ef4adeda-e04d-4306-8162-33e51f477fed');

  -- Each visit now lies in its membership's dates, within its session limit (BR-053).
  if exists (
    select 1
    from visits v
    join memberships ms on ms.id = v.membership_id
    where v.id in (
      'bfee4072-91e7-4ea9-a25c-fc4cd9b80f9c', 'e2f4bbd7-01d1-44af-bb36-e3540554ddfa',
      'c984e94b-5d04-40a0-b945-de3cc25440d2', '0e5e101e-1a40-49ba-a5a0-2ce733f271b4'
    )
      and (gym_local_date(v.gym_id, v.checked_in_at) not between ms.start_date and ms.end_date
        or membership_used(ms.id, 'group') > ms.group_session_limit)
  ) or (
    select count(*) from visits v
    join memberships ms on ms.id = v.membership_id
    where ms.id = '75230293-002e-4ecb-8c60-4bead00e45cc'
      and gym_local_date(v.gym_id, v.checked_in_at) not between ms.start_date and ms.end_date
  ) > 0 then
    raise exception 'D-106 repair: a visit falls outside its membership';
  end if;
end $$;
