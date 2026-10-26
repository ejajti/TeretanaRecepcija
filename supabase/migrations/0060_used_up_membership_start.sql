-- D-107 (BR-052 step 1): a membership whose sessions are all used up no longer holds the
-- next one back. Until now a sale continued after the latest comparable membership's
-- last day even when that one had nothing left: Hanna (#8) used her 12th Mjesečna 12
-- termina session on 19.10, came on 21.10 (an unpaid visit), paid that day, and the new
-- membership started on 22.10, so the visit of the day she paid stayed unpaid.
--
-- Now a comparable membership whose every limited type shared with the new plan is used
-- up counts as ending on the day of its last session of those types. Steps 2 and 3 then
-- apply as before: the new membership starts from the first unpaid visit after that day
-- (and links it), or today. A membership with a type left (unlimited, or sessions
-- remaining) still ends on its last day.
--
-- The repair at the end applies the rule to Hanna's sale of 21.10.2026, agreed with
-- Mihajlo on 26.10.2026: her membership 22.10–22.11 becomes 21.10–21.11 and takes the
-- 21.10 visit. It runs only where that row exists and is still as found that day.

/**
 * BR-052: where a new membership of this plan would start if sold on p_date (default:
 * gym today), as in migration 0012. D-107: L skips past the unused days of a comparable
 * membership whose sessions are all used up; it ends on the day of its last session.
 */
create or replace function calc_membership_start(p_member uuid, p_plan uuid, p_date date default null)
returns membership_start
language plpgsql
stable
set search_path = public
as $$
declare
  v_member members;
  v_plan   plans;
  v_date   date;
  v_last   date;
  v_first  date;
  v_end    date;
  v_result membership_start;
begin
  select * into v_member from members where id = p_member;
  select * into v_plan from plans where id = p_plan and gym_id = v_member.gym_id;
  if v_member.id is null or v_plan.id is null or v_plan.kind = 'day_pass' then
    raise exception 'E_VALIDATION';
  end if;
  v_date := coalesce(p_date, gym_today(v_member.gym_id));

  -- L: the latest end among the member's non-voided comparable memberships; for one with
  -- every shared type used up, the day of its last session of those types (D-107).
  select max(
    case
      when (not (m.covers_gym and v_plan.covers_gym)
            or membership_used(m.id, 'gym') >= m.gym_visit_limit)
       and (not (m.covers_group and v_plan.covers_group)
            or membership_used(m.id, 'group') >= m.group_session_limit)
       and (not (m.covers_personal and v_plan.covers_personal)
            or membership_used(m.id, 'personal') >= m.personal_session_limit)
      then coalesce(least(m.end_date, (
        select max(gym_local_date(v.gym_id, v.checked_in_at))
        from visits v
        where v.membership_id = m.id
          and ((v.visit_type = 'gym' and v_plan.covers_gym)
            or (v.visit_type = 'group' and v_plan.covers_group)
            or (v.visit_type = 'personal' and v_plan.covers_personal))
      )), m.end_date)
      else m.end_date
    end
  ) into v_last
  from memberships m
  where m.member_id = p_member
    and m.voided_at is null
    and ((m.covers_gym and v_plan.covers_gym)
      or (m.covers_group and v_plan.covers_group)
      or (m.covers_personal and v_plan.covers_personal));

  -- Step 1: continue after the membership that still runs on D (E2).
  if v_last >= v_date then
    v_result.start_date := v_last + 1;
    v_result.reason := 'Nastavlja se na članarinu koja važi do ' || to_char(v_last, 'DD.MM.YYYY');
  else
    -- Step 2: start from the first unpaid visit after L, if the membership would still
    -- be valid on D when started there (E3); otherwise warn and fall through (E5, AS-9).
    select min(gym_local_date(v.gym_id, v.checked_in_at)) into v_first
    from visits v
    where v.member_id = p_member
      and v.is_unpaid and v.membership_id is null
      and ((v.visit_type = 'gym' and v_plan.covers_gym)
        or (v.visit_type = 'group' and v_plan.covers_group)
        or (v.visit_type = 'personal' and v_plan.covers_personal))
      and (v_last is null or gym_local_date(v.gym_id, v.checked_in_at) > v_last)
      and gym_local_date(v.gym_id, v.checked_in_at) <= v_date;

    if v_first is not null then
      v_end := membership_end_date(v_first, v_plan.duration_value, v_plan.duration_unit);
      if v_end >= v_date then
        v_result.start_date := v_first;
        v_result.reason := 'Počinje od prvog neplaćenog dolaska ' || to_char(v_first, 'DD.MM.YYYY');
        select array_agg(v.id order by v.checked_in_at) into v_result.visit_ids
        from visits v
        where v.member_id = p_member
          and v.is_unpaid and v.membership_id is null
          and ((v.visit_type = 'gym' and v_plan.covers_gym)
            or (v.visit_type = 'group' and v_plan.covers_group)
            or (v.visit_type = 'personal' and v_plan.covers_personal))
          and gym_local_date(v.gym_id, v.checked_in_at) between v_first and least(v_end, v_date);
      else
        v_result.warning := 'Neplaćeni dolasci su stariji od trajanja ove članarine i ostaju neplaćeni.';
      end if;
    end if;

    -- Step 3: start on D.
    if v_result.start_date is null then
      v_result.start_date := v_date;
      v_result.reason := 'Počinje danas';
    end if;
  end if;

  v_result.end_date := membership_end_date(v_result.start_date, v_plan.duration_value, v_plan.duration_unit);
  v_result.visit_ids := coalesce(v_result.visit_ids, '{}');
  return v_result;
end;
$$;

-- Repair: Hanna (#8), sold on 21.10.2026 ---------------------------------------------------
do $$
declare
  v_ok int;
begin
  if not exists (select 1 from memberships where id = '5c5b93b1-7152-4f44-ba95-84ca8dfa67bf') then
    raise notice 'D-107 repair: the production membership is not in this database, skipped';
    return;
  end if;

  -- The old membership: all 12 gym sessions used, the last on 19.10.
  select count(*) into v_ok
  from memberships ms join members m on m.id = ms.member_id
  where ms.id = '61cbc399-6050-41d3-8b00-51acba88180f' and m.member_number = 8
    and ms.voided_at is null and ms.end_date = date '2026-10-21'
    and ms.gym_visit_limit = 12 and membership_used(ms.id, 'gym') = 12
    and (select max(gym_local_date(v.gym_id, v.checked_in_at)) from visits v
         where v.membership_id = ms.id) = date '2026-10-19';
  -- The new one, as sold: 22.10–22.11, two visits, no pause.
  select v_ok + count(*) into v_ok
  from memberships ms join members m on m.id = ms.member_id
  where ms.id = '5c5b93b1-7152-4f44-ba95-84ca8dfa67bf' and m.member_number = 8
    and ms.voided_at is null and ms.start_date = date '2026-10-22' and ms.end_date = date '2026-11-22'
    and ms.covers_gym and not ms.covers_group and not ms.covers_personal
    and ms.gym_visit_limit = 12 and membership_used(ms.id, 'gym') = 2
    and (select count(*) from visits x where x.membership_id = ms.id) = 2
    and not exists (select 1 from membership_pauses mp where mp.membership_id = ms.id);
  -- The visit of 21.10 16:35: an unlinked unpaid gym visit.
  select v_ok + count(*) into v_ok
  from visits v join members m on m.id = v.member_id
  where v.id = 'bb079caf-24e2-4b21-a743-63c88d4bacfe' and m.member_number = 8
    and to_char(v.checked_in_at at time zone 'Europe/Podgorica', 'YYYY-MM-DD HH24:MI') = '2026-10-21 16:35'
    and v.visit_type = 'gym' and v.is_unpaid and v.membership_id is null;
  if v_ok <> 3 then
    raise exception 'D-107 repair: % of the 3 rows are as found on 26.10.2026', v_ok;
  end if;

  -- BR-052 step 2 under D-107 (the audit trigger records the change).
  update memberships
  set start_date = date '2026-10-21',
      end_date = membership_end_date(date '2026-10-21', p.duration_value, p.duration_unit),
      start_reason = 'Počinje od prvog neplaćenog dolaska 21.10.2026'
  from plans p
  where memberships.id = '5c5b93b1-7152-4f44-ba95-84ca8dfa67bf' and p.id = memberships.plan_id;

  -- Linked, as a sale links it; is_unpaid stays true as history.
  update visits
  set membership_id = '5c5b93b1-7152-4f44-ba95-84ca8dfa67bf'
  where id = 'bb079caf-24e2-4b21-a743-63c88d4bacfe';

  if exists (
    select 1 from visits v join memberships ms on ms.id = v.membership_id
    where ms.id = '5c5b93b1-7152-4f44-ba95-84ca8dfa67bf'
      and gym_local_date(v.gym_id, v.checked_in_at) not between ms.start_date and ms.end_date
  ) then
    raise exception 'D-107 repair: a visit falls outside the membership';
  end if;
end $$;
