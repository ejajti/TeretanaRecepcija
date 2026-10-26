-- Migration 0057, doc 04 §2: membership_shares and open_shift are internal helpers that
-- no API role may call. The owner reads the shares only through the fin_ reports, which
-- still reach them (0012_finance: fin_trainer_stats and fin_trainer_payments).
select plan(10);

-- Fixtures --------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('57575757-0000-0000-0000-00000000a001', null),
  ('57575757-0000-0000-0000-00000000a002', null),
  ('57575757-0000-0000-0000-00000000a003', null);
insert into gyms (id, name, timezone) values
  ('57575757-0000-0000-0000-00000000b001', 'pgTAP Interne funkcije', 'Europe/Podgorica');
insert into gym_settings (gym_id) values ('57575757-0000-0000-0000-00000000b001');
insert into staff (id, gym_id, user_id, role, full_name, username) values
  ('57575757-0000-0000-0000-00000000c001', '57575757-0000-0000-0000-00000000b001',
   '57575757-0000-0000-0000-00000000a001', 'owner', 'pgTAP Vlasnik', 'pgtap.int.vlasnik'),
  ('57575757-0000-0000-0000-00000000c002', '57575757-0000-0000-0000-00000000b001',
   '57575757-0000-0000-0000-00000000a002', 'manager', 'pgTAP Menadzer', 'pgtap.int.menadzer'),
  ('57575757-0000-0000-0000-00000000c003', '57575757-0000-0000-0000-00000000b001',
   '57575757-0000-0000-0000-00000000a003', 'receptionist', 'pgTAP Ana', 'pgtap.int.ana');

-- Receptionist ----------------------------------------------------------------------
set local request.jwt.claims = '{"sub": "57575757-0000-0000-0000-00000000a003"}';
set local role authenticated;

select throws_ok(
  $$select membership_shares('57575757-0000-0000-0000-000000020001', 100)$$,
  '42501', null, 'Doc 04 §2: a receptionist cannot read a trainer share through membership_shares');
select throws_ok(
  $$select open_shift('57575757-0000-0000-0000-00000000b001')$$,
  '42501', null, 'Doc 04 §2: a receptionist cannot call open_shift for any gym');

-- Manager ---------------------------------------------------------------------------
reset role;
set local request.jwt.claims = '{"sub": "57575757-0000-0000-0000-00000000a002"}';
set local role authenticated;

select throws_ok(
  $$select membership_shares('57575757-0000-0000-0000-000000020001', 100)$$,
  '42501', null, 'Doc 04 §2: a manager cannot read a trainer share through membership_shares');
select throws_ok(
  $$select open_shift('57575757-0000-0000-0000-00000000b001')$$,
  '42501', null, 'Doc 04 §2: a manager cannot call open_shift for any gym');

-- Owner -----------------------------------------------------------------------------
reset role;
set local request.jwt.claims = '{"sub": "57575757-0000-0000-0000-00000000a001"}';
set local role authenticated;

select throws_ok(
  $$select membership_shares('57575757-0000-0000-0000-000000020001', 100)$$,
  '42501', null, 'Doc 04 §2: the owner reads shares only through the fin_ reports');

-- Privileges and settings -----------------------------------------------------------
reset role;

select ok(
  not has_function_privilege('anon', 'public.membership_shares(uuid, numeric)', 'execute'),
  'Doc 04 §2: anon cannot call membership_shares');
select ok(
  not has_function_privilege('anon', 'public.open_shift(uuid)', 'execute'),
  'Doc 04 §2: anon cannot call open_shift');
select ok(
  to_regprocedure('public.rls_auto_enable()') is null
  or not (has_function_privilege('anon', 'public.rls_auto_enable()', 'execute')
          or has_function_privilege('authenticated', 'public.rls_auto_enable()', 'execute')),
  'Supabase''s rls_auto_enable is not callable by anon or authenticated');
select is(
  (select proconfig from pg_proc where oid = 'public.random_card_code()'::regprocedure),
  array['search_path=public'],
  'Doc 07 §4: random_card_code has a fixed search_path');
select is(
  (select proconfig from pg_proc
   where oid = 'public.class_slot_trainer_assigned()'::regprocedure),
  array['search_path=public'],
  'Doc 07 §4: class_slot_trainer_assigned has a fixed search_path');

select * from finish();
