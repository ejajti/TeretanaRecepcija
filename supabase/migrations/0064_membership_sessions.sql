-- D-111 (BR-055a): the owner and the admin change how many sessions a membership has
-- left, on S-07 [Izmijeni termine]. A paid Mjesečna 12 termina can, for example, get two
-- sessions more or fewer. Only the session count changes: the dates, the amount, the
-- payment and the trainer stay as sold (BR-050), so no shift is needed (BR-092), and
-- the memberships trigger writes the change to the audit log (BR-096).
--
-- The new limit is the sessions already used plus the number left that was typed. When
-- sessions are added, the member's unlinked unpaid visits of that type dated within the
-- membership are linked to it first, oldest first, and use the new sessions, as a sale
-- links them (BR-052 step 2). Otherwise they would stay unpaid for good: a membership
-- with sessions left holds the next sale back to its last day (D-107), and that sale
-- links only visits after it.

-- A Personalni membership may now hold more than the 50 sessions a sale allows (the
-- sale still checks 1 to 50 itself, BR-059). No membership ever holds fewer than one.
alter table memberships drop constraint memberships_personal_session_limit_check;
alter table memberships add constraint memberships_session_limits_check
  check (gym_visit_limit >= 1 and group_session_limit >= 1 and personal_session_limit >= 1);

/**
 * D-111 (BR-055a): sets the sessions left of each limited type of p_membership whose
 * argument is not null: 0 to 99, and at least 1 while none of that type is used. Owner
 * and admin only; any non-voided membership, expired ones too. Answers
 * {membership_id, linked, unpaid_count}: the unpaid visits it linked and those the
 * member still has (US-10.1).
 */
create function set_membership_sessions(
  p_membership    uuid,
  p_gym_left      integer default null,
  p_group_left    integer default null,
  p_personal_left integer default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff    staff := current_staff();
  v_old      memberships;
  v_new      memberships;
  v_gym      integer;
  v_group    integer;
  v_personal integer;
  v_type     visit_type;
  v_left     integer;
  v_count    integer;
  v_linked   integer := 0;
begin
  -- P-24b: the owner and the admin only.
  if v_staff.role not in ('owner', 'admin') then
    raise exception 'E_FORBIDDEN';
  end if;

  -- S-07: an anonymized profile is read-only.
  select ms.* into v_old
  from memberships ms
  join members m on m.id = ms.member_id
  where ms.id = p_membership and ms.gym_id = v_staff.gym_id and not m.is_anonymized;
  if not found then
    raise exception 'E_FORBIDDEN';
  end if;
  -- The member row lock serialises this with the member's check-ins and sales (BR-071),
  -- so the sessions counted as used stay used until the change is saved.
  perform 1 from members where id = v_old.member_id for update;
  select * into v_old from memberships where id = p_membership for update;

  if v_old.voided_at is not null
     or (p_gym_left is null and p_group_left is null and p_personal_left is null) then
    raise exception 'E_VALIDATION';
  end if;

  -- Only a covered type with a limit has sessions to change; Neograničeno stays so.
  v_gym := v_old.gym_visit_limit;
  if p_gym_left is not null then
    if not v_old.covers_gym or v_old.gym_visit_limit is null then
      raise exception 'E_VALIDATION';
    end if;
    v_gym := membership_used(v_old.id, 'gym') + p_gym_left;
  end if;
  v_group := v_old.group_session_limit;
  if p_group_left is not null then
    if not v_old.covers_group or v_old.group_session_limit is null then
      raise exception 'E_VALIDATION';
    end if;
    v_group := membership_used(v_old.id, 'group') + p_group_left;
  end if;
  v_personal := v_old.personal_session_limit;
  if p_personal_left is not null then
    if not v_old.covers_personal or v_old.personal_session_limit is null then
      raise exception 'E_VALIDATION';
    end if;
    v_personal := membership_used(v_old.id, 'personal') + p_personal_left;
  end if;
  if p_gym_left not between 0 and 99 or p_group_left not between 0 and 99
     or p_personal_left not between 0 and 99
     or v_gym < 1 or v_group < 1 or v_personal < 1 then
    raise exception 'E_SESSIONS_INVALID';
  end if;

  update memberships
  set gym_visit_limit = v_gym, group_session_limit = v_group,
      personal_session_limit = v_personal
  where id = v_old.id
    and (gym_visit_limit, group_session_limit, personal_session_limit)
        is distinct from (v_gym, v_group, v_personal)
  returning * into v_new;

  -- Sessions added: the unpaid visits of that type from the membership's days take them
  -- first, oldest first, never more than the sessions now left. A paused day covers
  -- nothing (BR-053), so a visit on one stays as it is. is_unpaid stays true as history,
  -- as when a sale links a visit (D-106).
  foreach v_type in array array['gym', 'group', 'personal']::visit_type[] loop
    v_left := case v_type
      when 'gym' then p_gym_left
      when 'group' then p_group_left
      else p_personal_left
    end;
    continue when v_left is null or v_left = 0
      or case v_type
           when 'gym' then v_gym <= v_old.gym_visit_limit
           when 'group' then v_group <= v_old.group_session_limit
           else v_personal <= v_old.personal_session_limit
         end;

    update visits v
    set membership_id = v_old.id
    where v.id in (
      select u.id
      from visits u
      where u.member_id = v_old.member_id
        and u.membership_id is null
        and u.is_unpaid
        and u.visit_type = v_type
        and gym_local_date(u.gym_id, u.checked_in_at) between v_old.start_date and v_old.end_date
        and not exists (
          select 1 from membership_pauses p
          where p.membership_id = v_old.id
            and gym_local_date(u.gym_id, u.checked_in_at) between p.paused_from and p.paused_until
        )
      order by u.checked_in_at
      limit v_left
    );
    get diagnostics v_count = row_count;
    v_linked := v_linked + v_count;
  end loop;

  return json_build_object(
    'membership_id', v_old.id,
    'linked', v_linked,
    'unpaid_count', unlinked_unpaid_count(v_old.member_id)
  );
end;
$$;

-- Signed-in staff only; the function checks the role itself (P-24b: owner and admin).
revoke execute on function set_membership_sessions(uuid, integer, integer, integer)
  from public, anon;
