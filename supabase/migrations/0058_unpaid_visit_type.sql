-- D-106: an unpaid visit is recorded with the type the member came for, so that paying
-- for the next membership covers it, and "Prijavi odmah" records a visit only when the
-- membership just sold is valid today.
--
-- 1. BR-073: a member with nothing valid today whose latest membership (the one that
--    ended last) was Grupni only or Personalni only gets an unpaid visit of that type,
--    with that membership's trainer: Grupni at their class (D-71, ±90 minutes, AS-12),
--    Personalni at once. Until now it was always an unpaid gym visit, which a new
--    Grupni or Personalni could never cover (BR-052 step 2 links covered types only),
--    so the unpaid badge stayed after the member paid. Outside the class, with G+T or
--    a gym membership last, or with no earlier membership, it is an unpaid gym visit,
--    as before. A Grupni-only member with a valid membership outside their class still
--    gets an unpaid gym visit (D-102).
-- 2. "Prijavi odmah" (D-31): no visit when the membership just sold is not valid today
--    (its start chosen later, D-97). A new Grupni member is checked in to their class
--    today at any hour, as a covered group visit; on a day their trainer holds no class,
--    no visit is recorded.
--
-- Migration 0059 applies the same rules to the visits already recorded.

/**
 * D-106: the class a new Grupni member is checked in to at registration. The trainer's
 * active group slot today at the member's class time (D-71) at any hour, otherwise the
 * trainer's slot today nearest now; null on a day the trainer holds no class.
 */
create function trainer_class_today(p_gym uuid, p_trainer uuid, p_class_time time)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  with local_now as (
    select (now() at time zone g.timezone) as ts from gyms g where g.id = p_gym
  )
  select cs.id
  from class_slots cs
  join programs pr on pr.id = cs.program_id
  cross join local_now n
  where cs.gym_id = p_gym
    and cs.trainer_id = p_trainer
    and cs.is_active
    and pr.is_active
    and pr.kind = 'group'
    and cs.weekday = extract(isodow from n.ts)
  order by (cs.starts_at = p_class_time) desc nulls last,
           abs(extract(epoch from (cs.starts_at - n.ts::time))), cs.starts_at
  limit 1;
$$;

/**
 * D-102 (BR-073): the visit recorded without a question, or null when S-03a is needed,
 * as in migration 0052. D-106: with nothing valid today, a member whose latest
 * membership was Grupni only (at their class) or Personalni only gets an unpaid visit of
 * that type with its trainer, which the next sale of that kind links (BR-052 step 2).
 */
create or replace function auto_check_in(p_staff staff, p_member uuid, p_manual boolean)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := gym_today(p_staff.gym_id);
  v_gym   boolean;
  v_group boolean;
  v_pers  boolean;
  v_type  visit_type;
  v_ref   memberships;
  v_last  memberships;
  v_paid  boolean;
  v_slot  uuid;
begin
  select coalesce(bool_or(m.covers_gym), false),
         coalesce(bool_or(m.covers_group), false),
         coalesce(bool_or(m.covers_personal), false)
  into v_gym, v_group, v_pers
  from memberships m
  where m.member_id = p_member and m.voided_at is null
    and v_today between m.start_date and m.end_date;

  -- Two or more types (G+T, or Teretana with Grupni or Personalni) need S-03a.
  if v_gym::int + v_group::int + v_pers::int >= 2 then
    return null;
  end if;

  -- D-106: nothing valid, and the membership that ended last was Grupni or Personalni
  -- only: an unpaid visit of that type, with its trainer while they still qualify.
  if not (v_gym or v_group or v_pers) then
    select m.* into v_last
    from memberships m
    where m.member_id = p_member and m.voided_at is null and m.end_date < v_today
    order by m.end_date desc, m.created_at desc
    limit 1;

    if v_last.trainer_id is not null and not v_last.covers_gym then
      if v_last.covers_personal and not v_last.covers_group
         and trainer_can(v_last.trainer_id, 'personal') then
        return perform_check_in(
          p_staff, p_member, 'personal', null, v_last.trainer_id, null, p_manual
        );
      end if;
      if v_last.covers_group and not v_last.covers_personal
         and trainer_can(v_last.trainer_id, 'group') then
        v_slot := member_class_slot(p_staff.gym_id, v_last.trainer_id, v_last.class_time);
        if v_slot is not null then
          return perform_check_in(
            p_staff, p_member, 'group', null, v_last.trainer_id, v_slot, p_manual
          );
        end if;
      end if;
    end if;
  end if;

  -- Teretana only, or nothing valid (BR-078): the BR-074 default, or an unpaid visit.
  if not (v_group or v_pers) then
    return perform_check_in(p_staff, p_member, 'gym', null, null, null, p_manual);
  end if;

  v_type := case when v_group then 'group' else 'personal' end;
  -- The membership the visit belongs to: one that still covers the type, earliest end
  -- first (BR-074); with every one used up, the one valid today, for its trainer and class.
  select m.* into v_ref
  from memberships m
  where m.member_id = p_member and m.voided_at is null
    and v_today between m.start_date and m.end_date
    and case v_type when 'group' then m.covers_group else m.covers_personal end
  order by membership_covers(m.id, v_type, v_today) desc, m.end_date, m.created_at
  limit 1;
  v_paid := membership_covers(v_ref.id, v_type, v_today);

  -- BR-075, BR-076: the trainer is required; one who no longer qualifies is chosen on S-03a.
  if v_ref.trainer_id is null
     or not trainer_can(v_ref.trainer_id, v_type::text::program_kind) then
    return null;
  end if;

  if v_type = 'personal' then
    return perform_check_in(
      p_staff, p_member, 'personal', case when v_paid then v_ref.id end,
      v_ref.trainer_id, null, p_manual
    );
  end if;

  v_slot := member_class_slot(p_staff.gym_id, v_ref.trainer_id, v_ref.class_time);
  if v_slot is null then
    -- Outside the member's class: an unpaid gym visit (BR-078).
    return perform_check_in(p_staff, p_member, 'gym', null, null, null, p_manual);
  end if;
  return perform_check_in(
    p_staff, p_member, 'group', case when v_paid then v_ref.id end,
    v_ref.trainer_id, v_slot, p_manual
  );
end;
$$;

/**
 * F-06 with "Prijavi odmah" (D-31, US-06.1 AC2), as in migration 0052. D-106: the visit
 * is recorded only when the membership just sold is valid today, and a new Grupni member
 * is checked in to their class today at any hour (none on a day without one).
 */
create or replace function register_member(
  p_card_code text,
  p_first text,
  p_last text,
  p_phone text,
  p_email text,
  p_dob date,
  p_plan uuid,
  p_trainer uuid,
  p_amount numeric,
  p_sessions integer,
  p_method payment_method,
  p_check_in boolean default false,
  p_class_time time default null,
  p_start_override date default null,
  p_gym_fee numeric default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff   staff := current_staff();
  v_shift   shifts := require_open_shift(v_staff.gym_id);
  v_card    cards;
  v_fields  members;
  v_number  integer;
  v_member  members;
  v_sale    json;
  v_new     memberships;
  v_slot    uuid;
  v_options json;
  v_type    text;
  v_cand    json;
  v_trainer uuid;
  v_visit   json;
begin
  v_card := unassigned_card(v_staff.gym_id, p_card_code);
  v_fields := clean_member(v_staff.gym_id, p_first, p_last, p_phone, p_email, p_dob);

  -- BR-042: sequential per gym, never reused; the row lock serialises registrations.
  insert into member_counters (gym_id, last_number) values (v_staff.gym_id, 1)
  on conflict (gym_id) do update set last_number = member_counters.last_number + 1
  returning last_number into v_number;

  insert into members (
    gym_id, member_number, first_name, last_name, phone, email, date_of_birth, created_by
  ) values (
    v_staff.gym_id, v_number, v_fields.first_name, v_fields.last_name, v_fields.phone,
    v_fields.email, v_fields.date_of_birth, v_staff.id
  )
  returning * into v_member;

  update cards
  set status = 'active', member_id = v_member.id, assigned_at = now()
  where id = v_card.id;

  v_sale := membership_sale(
    v_staff, v_shift.id, v_member.id, p_plan, p_trainer, p_amount, p_sessions, p_method,
    p_start_override, null, false, p_class_time, p_gym_fee
  );
  select * into v_new from memberships where id = (v_sale ->> 'membership_id')::uuid;

  -- D-106: only with a membership valid today; one that starts later records no visit.
  if coalesce(p_check_in, false)
     and gym_today(v_staff.gym_id) between v_new.start_date and v_new.end_date then
    if v_new.covers_group and not v_new.covers_gym and not v_new.covers_personal then
      -- D-106: a new Grupni member, at any hour, to their class today.
      v_slot := trainer_class_today(v_staff.gym_id, v_new.trainer_id, v_new.class_time);
      if v_slot is not null then
        v_visit := perform_check_in(
          v_staff, v_member.id, 'group', v_new.id, v_new.trainer_id, v_slot, false
        );
      end if;
    else
      -- D-102: as a scan records it; G+T takes the BR-073 preselection instead of asking.
      v_visit := auto_check_in(v_staff, v_member.id, false);
      if v_visit is null then
        v_options := check_in_options(v_member.id);
        v_type := v_options ->> 'preselect';
        v_cand := v_options -> 'candidates' -> v_type -> 0;
        v_trainer := case when v_type = 'gym' then null else (v_cand ->> 'trainer_id')::uuid end;
        v_visit := perform_check_in(
          v_staff, v_member.id, v_type::visit_type, (v_cand ->> 'id')::uuid, v_trainer,
          case when v_type = 'group' then default_class_slot(v_staff.gym_id, v_trainer) end,
          false
        );
      end if;
    end if;
  end if;

  return json_build_object(
    'member_id', v_member.id,
    'member_number', v_member.member_number,
    'first_name', v_member.first_name,
    'last_name', v_member.last_name,
    'membership', v_sale,
    'check_in', v_visit
  );
end;
$$;

-- Function privileges ---------------------------------------------------------------------
-- Internal, like member_class_slot (migration 0052). auto_check_in and register_member
-- keep their privileges (create or replace).
revoke execute on function trainer_class_today(uuid, uuid, time)
  from public, anon, authenticated;
