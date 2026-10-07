-- D-102 (BR-073): the visit-type question (S-03a) is asked only when the member's
-- memberships valid today cover two or more visit types: G+T, or Teretana and Grupni or
-- Personalni held as separate memberships. Every other scan or manual start records the
-- visit at once:
--   * Teretana only (or nothing valid): a gym visit with the BR-074 default membership,
--     now also when two gym memberships cover today (no membership selector);
--   * Grupni only: a group visit with the membership's trainer and the member's own class
--     (the fixed class time of D-71, held today, starting within ±90 minutes of now). Used
--     up sessions make it an unpaid group visit, which shows the yellow or red dialog.
--     Outside the member's class it is an unpaid gym visit: a Grupni-only member may not
--     train in the gym at other times;
--   * Personalni only: a personal visit with the membership's trainer, unpaid when its
--     sessions are used up.
-- A visit always has its trainer (BR-075, BR-076): if the membership's trainer can no
-- longer take that kind of visit (BR-023), S-03a is shown so the desk picks one.
--
-- The scan, [Ručna prijava] and the reception search all reach start_check_in. "Prijavi
-- odmah" at registration (D-31) follows the same rule; a new G+T member still takes the
-- BR-073 preselection (Teretana) there, as before, since registration shows no S-03a.
-- check_in_options and S-03a are unchanged.

/**
 * D-102 (BR-075, AS-12): the member's class now. With a fixed class time (D-71), the
 * trainer's active group slot at that time on today's weekday, if it starts within ±90
 * minutes of now; without one (a membership sold before D-71), the trainer's nearest slot
 * as BR-075 chooses it. Null means the member is outside their class.
 */
create function member_class_slot(p_gym uuid, p_trainer uuid, p_class_time time)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  with local_now as (
    select (now() at time zone g.timezone) as ts from gyms g where g.id = p_gym
  )
  select case
    when p_class_time is null then default_class_slot(p_gym, p_trainer)
    else (
      select cs.id
      from class_slots cs
      join programs pr on pr.id = cs.program_id
      cross join local_now n
      where cs.gym_id = p_gym
        and cs.trainer_id = p_trainer
        and cs.starts_at = p_class_time
        and cs.is_active
        and pr.is_active
        and pr.kind = 'group'
        and cs.weekday = extract(isodow from n.ts)
        and abs(extract(epoch from (cs.starts_at - n.ts::time))) <= 90 * 60
      limit 1
    )
  end;
$$;

/** S-03a's answer: the member and the BR-073 to BR-076 options, as in migration 0050. */
create function start_check_in_choose(p_member uuid, p_manual boolean, p_pause_ended boolean)
returns json
language sql
stable
security definer
set search_path = public
as $$
  select json_build_object(
    'result', 'choose',
    'member', member_brief(p_member),
    'manual', coalesce(p_manual, false),
    'options', check_in_options(p_member),
    'pause_ended', p_pause_ended
  );
$$;

/**
 * D-102 (BR-073): the visit recorded without a question, or null when S-03a is needed.
 * "Covers" here means a membership valid today whose coverage includes the type, even
 * with its sessions used up, as BR-073 offers it. Shared by start_check_in and
 * register_member; a pause that has begun is ended by the caller first (D-100).
 */
create function auto_check_in(p_staff staff, p_member uuid, p_manual boolean)
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
 * BR-073 and US-04.2, as in migration 0050 (D-100 ends a begun pause first), with the
 * D-102 decision of when S-03a is needed.
 */
create or replace function start_check_in(p_staff staff, p_member uuid, p_manual boolean)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ended boolean := end_member_pauses(p_member, gym_today(p_staff.gym_id));
  v_visit json := auto_check_in(p_staff, p_member, p_manual);
begin
  if v_visit is null then
    return start_check_in_choose(p_member, p_manual, v_ended);
  end if;
  return json_build_object(
    'result', 'checked_in',
    'check_in', v_visit,
    'pause_ended', v_ended
  );
end;
$$;

/**
 * F-06 with "Prijavi odmah" (D-31, US-06.1 AC2), as in migration 0049, with the visit
 * recorded as a scan would record it (D-102): a new Grupni member registered outside
 * their class gets an unpaid gym visit. A new G+T member, whom a scan would ask, takes
 * BR-073's preselection with the membership just sold and its BR-075 default slot.
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

  if coalesce(p_check_in, false) then
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
-- Internal: only other security definer functions call these. start_check_in and
-- register_member keep their privileges (create or replace).
revoke execute on function
  member_class_slot(uuid, uuid, time),
  start_check_in_choose(uuid, boolean, boolean),
  auto_check_in(staff, uuid, boolean)
  from public, anon, authenticated;
