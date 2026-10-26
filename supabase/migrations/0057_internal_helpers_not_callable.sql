-- Doc 04 §2 point 2: trainer shares never reach a manager or a receptionist, "even
-- through the API directly".
--
-- The Supabase Security Advisor (26.10.2026) showed two internal helpers that any
-- signed-in staff member could still call through /rest/v1/rpc:
--
-- - membership_shares(p_membership, p_amount) reads the owner-only membership_finance
--   and returns the trainer's and the gym's share (BR-155) with no role check. Called
--   with an amount of 100, it gave a receptionist the trainer's percentage for every
--   membership.
-- - open_shift(p_gym) (doc 07 §4) returns the open shift of any gym, not only the
--   caller's.
--
-- Only security definer functions call them, and those run as their owner, so they
-- keep working: fin_trainer_payments and fin_trainer_stats (both start with
-- assert_owner) for membership_shares; session_context and the desk RPCs for
-- open_shift. The app never calls either one itself.
--
-- rls_auto_enable() is Supabase's own event trigger function that enables RLS on new
-- tables. It cannot be called as a function, but anon and authenticated held EXECUTE
-- on it. postgres, which runs the migrations and owns the function, keeps it.
--
-- random_card_code() and the class_slots trigger class_slot_trainer_assigned() get the
-- fixed search_path that the other functions have (doc 07 §4).
--
-- Only privileges and the search_path setting change. No table, row or function body
-- does.

revoke execute on function membership_shares(uuid, numeric) from public, anon, authenticated;
revoke execute on function open_shift(uuid) from public, anon, authenticated;

do $$
begin
  -- It exists only where the dashboard's automatic RLS created it, so a fresh project
  -- (the restore test, BR-163) runs this migration without it.
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke execute on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end $$;

alter function random_card_code() set search_path = public;
alter function class_slot_trainer_assigned() set search_path = public;
