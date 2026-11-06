import { expect, test, type Page } from "@playwright/test";
import {
  adminClient,
  createTestGym,
  createTestStaff,
  deleteTestGym,
  suffix,
  type TestStaff,
} from "./fixtures";

// D-111 (BR-055a, P-24b): on S-07 the owner and the admin change how many sessions a
// membership has left; the dates stay. Added sessions first link the member's unpaid
// visits from the membership's days. A receptionist does not get the button.
// Everything lives in this test's own gym, which afterAll removes.
test.describe.configure({ mode: "serial" });

const PASSWORD = "terminilozinka1";
const PLAN = "E2E Mjesečna 3 termina";

let gymId: string;
let owner: TestStaff;
let receptionist: TestStaff;
let memberId: string;
let membershipId: string;
let start: string;
let end: string;

async function must<T>(
  query: PromiseLike<{ data: T | null; error: { message: string } | null }>,
  what: string,
): Promise<T> {
  const { data, error } = await query;
  if (error || data === null)
    throw new Error(`${what} not created: ${error?.message}`);
  return data;
}

/** A yyyy-mm-dd day moved by whole days. */
function addDays(day: string, days: number): string {
  const date = new Date(`${day}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

/** dd.mm.yyyy, as the screens write a date. */
function shown(day: string): string {
  const [year, month, date] = day.split("-");
  return `${date}.${month}.${year}`;
}

/** 10:00 in Podgorica on that day (UTC+1 or UTC+2), safely inside the gym date. */
function visitAt(day: string): string {
  return `${day}T09:00:00Z`;
}

test.beforeAll(async ({}, workerInfo) => {
  gymId = await createTestGym(
    `${workerInfo.project.name}-sessions-${suffix()}`,
  );
  owner = await createTestStaff(gymId, {
    role: "owner",
    fullName: "E2E Vlasnik termina",
    password: PASSWORD,
  });
  receptionist = await createTestStaff(gymId, {
    role: "receptionist",
    fullName: "E2E Recepcija termina",
    password: PASSWORD,
  });

  const admin = adminClient();
  const { data: today } = await admin.rpc("gym_today", { p_gym: gymId });
  start = addDays(today as string, -20);
  end = addDays(today as string, 10);

  const plan = await must(
    admin
      .from("plans")
      .insert({
        gym_id: gymId,
        name: PLAN,
        kind: "gym",
        duration_value: 1,
        duration_unit: "month",
        price: 39,
        covers_gym: true,
        covers_group: false,
        covers_personal: false,
        gym_visit_limit: 3,
        requires_trainer: false,
        sort_order: 1,
      })
      .select("id")
      .single<{ id: string }>(),
    "Test plan",
  );
  await must(
    admin
      .from("plan_finance")
      .insert({ plan_id: plan.id, gym_id: gymId })
      .select("plan_id"),
    "Test plan finance",
  );
  const member = await must(
    admin
      .from("members")
      .insert({
        gym_id: gymId,
        member_number: 1,
        first_name: "E2E Termini",
        last_name: "Član",
        phone: "+38267311001",
        email: "termini1@e2e.invalid",
        date_of_birth: "1990-01-01",
        created_by: owner.id,
      })
      .select("id")
      .single<{ id: string }>(),
    "Test member",
  );
  memberId = member.id;
  await must(
    admin
      .from("member_counters")
      .insert({ gym_id: gymId, last_number: 1 })
      .select("gym_id"),
    "Test member counter",
  );

  // Back-dated (BR-120), so no shift is needed: all 3 sessions used, then one unpaid
  // gym visit five days ago.
  const membership = await must(
    admin
      .from("memberships")
      .insert({
        gym_id: gymId,
        member_id: memberId,
        plan_id: plan.id,
        start_date: start,
        end_date: end,
        start_reason: "E2E",
        covers_gym: true,
        covers_group: false,
        covers_personal: false,
        gym_visit_limit: 3,
        is_backdated: true,
        created_by: owner.id,
      })
      .select("id")
      .single<{ id: string }>(),
    "Test membership",
  );
  membershipId = membership.id;
  await must(
    admin
      .from("visits")
      .insert(
        [-15, -12, -9, -5].map((days, index) => ({
          gym_id: gymId,
          member_id: memberId,
          membership_id: index < 3 ? membershipId : null,
          visit_type: "gym",
          is_unpaid: index === 3,
          checked_in_at: visitAt(addDays(today as string, days)),
          checked_out_at: visitAt(addDays(today as string, days)).replace(
            "T09:",
            "T10:",
          ),
          checked_in_by: receptionist.id,
          is_backdated: false,
        })),
      )
      .select("id"),
    "Test visits",
  );
});

test.afterAll(async () => {
  await deleteTestGym(gymId);
});

async function signIn(page: Page, staff: TestStaff) {
  await page.goto("/login");
  await page.getByLabel("Korisničko ime ili email").fill(staff.identifier);
  await page.getByLabel("Lozinka", { exact: true }).fill(PASSWORD);
  await page.getByRole("button", { name: "Prijavi se" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/login"));
}

test("P-24b: a receptionist has no [Izmijeni broj termina]", async ({
  page,
}) => {
  await signIn(page, receptionist);
  await page.goto(`/members/${memberId}`);
  await expect(page.locator("tr", { hasText: PLAN })).toBeVisible();
  await expect(
    page.getByRole("button", { name: `Izmijeni broj termina ${PLAN}` }),
  ).toHaveCount(0);
});

test("D-111: the owner adds sessions; the unpaid visit takes one, the dates stay", async ({
  page,
}) => {
  await signIn(page, owner);
  await page.goto(`/members/${memberId}`);
  await expect(page.getByText("Neplaćeni dolasci: 1")).toBeVisible();
  const row = page.locator("tr", { hasText: PLAN });
  await expect(row).toContainText("Teretana: 0 preostalo");

  await row
    .getByRole("button", { name: `Izmijeni broj termina ${PLAN}` })
    .click();
  const dialog = page.getByRole("dialog");
  await expect(
    dialog.getByText(
      "Mijenja se samo broj termina. Datumi, iznos i uplata ostaju isti.",
    ),
  ).toBeVisible();
  const field = dialog.getByLabel("Teretana: preostalo termina");
  await expect(field).toHaveValue("0");
  await expect(dialog.getByText(/Iskorišteno 3 od 3\./)).toBeVisible();

  await field.fill("2");
  await expect(dialog.getByText(/Ukupno termina: 5\./)).toBeVisible();
  await expect(
    dialog.getByText(
      "Neplaćeni dolasci iz perioda ove članarine koji se povezuju: 1. Oni troše dodate termine, pa preostaje 1.",
    ),
  ).toBeVisible();

  // Out of range keeps [Sačuvaj] off.
  await field.fill("100");
  await expect(dialog.getByText(/Unesite broj od 0 do 99\./)).toBeVisible();
  await expect(dialog.getByRole("button", { name: "Sačuvaj" })).toBeDisabled();

  await field.fill("2");
  await dialog.getByRole("button", { name: "Sačuvaj" }).click();
  await expect(
    page
      .getByText("Broj termina je sačuvan. Povezani neplaćeni dolasci: 1.")
      .first(),
  ).toBeVisible();

  await expect(row).toContainText("Teretana: 1 preostalo");
  await expect(row).toContainText(shown(start));
  await expect(row).toContainText(shown(end));
  await expect(page.getByText("Neplaćeni dolasci: 1")).toHaveCount(0);

  const { data } = await adminClient()
    .from("memberships")
    .select("gym_visit_limit, start_date, end_date")
    .eq("id", membershipId)
    .single<{
      gym_visit_limit: number;
      start_date: string;
      end_date: string;
    }>();
  expect(data).toEqual({
    gym_visit_limit: 5,
    start_date: start,
    end_date: end,
  });
});

test("D-111: the owner takes sessions away; nothing is linked", async ({
  page,
}) => {
  await signIn(page, owner);
  await page.goto(`/members/${memberId}`);
  const row = page.locator("tr", { hasText: PLAN });
  await row
    .getByRole("button", { name: `Izmijeni broj termina ${PLAN}` })
    .click();
  const dialog = page.getByRole("dialog");
  await dialog.getByLabel("Teretana: preostalo termina").fill("0");
  await expect(dialog.getByText(/Ukupno termina: 4\./)).toBeVisible();
  await dialog.getByRole("button", { name: "Sačuvaj" }).click();
  await expect(
    page.getByText("Broj termina je sačuvan.", { exact: true }).first(),
  ).toBeVisible();
  await expect(row).toContainText("Teretana: 0 preostalo");
  await expect(row).toContainText("Iskorištena");
});
