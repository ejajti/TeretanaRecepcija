import { expect, test, type Page } from "@playwright/test";
import {
  adminClient,
  createTestGym,
  createTestStaff,
  deleteTestGym,
  suffix,
  type TestStaff,
} from "./fixtures";

// D-105 (BR-027a): S-29 Treneri has the tabs Grupni and Personalni. Personalni shows
// every role which members are assigned to which trainer for personal training, valid
// today or starting later, with the day paid, the last valid day and the sessions left.
// Only the owner and the admin see the amounts (BR-157). Everything runs in a test gym of
// its own, created and deleted here, so the real gym's data is never read or changed.
test.describe.configure({ mode: "serial" });

const PASSWORD = "personalnilozinka1";

let gymId: string;
let receptionist: TestStaff;
let owner: TestStaff;
let today: string;
let weekday: number;
const memberIds = new Map<number, string>();

async function must<T>(
  query: PromiseLike<{ data: T | null; error: { message: string } | null }>,
  what: string,
): Promise<T> {
  const { data, error } = await query;
  if (error || data === null)
    throw new Error(`${what} not created: ${error?.message}`);
  return data;
}

function addDays(date: string, days: number) {
  const value = new Date(`${date}T12:00:00Z`);
  value.setUTCDate(value.getUTCDate() + days);
  return value.toISOString().slice(0, 10);
}

/** As formatDate shows a database date: 18.11.2026. */
function shown(date: string) {
  const [year, month, day] = date.split("-");
  return `${day}.${month}.${year}`;
}

test.beforeAll(async ({}, workerInfo) => {
  gymId = await createTestGym(
    `${workerInfo.project.name}-personalni-${suffix()}`,
  );
  receptionist = await createTestStaff(gymId, {
    role: "receptionist",
    fullName: "E2E Recepcija personalnih",
    password: PASSWORD,
  });
  owner = await createTestStaff(gymId, {
    role: "owner",
    fullName: "E2E Vlasnik personalnih",
    password: PASSWORD,
  });

  const admin = adminClient();
  // BR-001: the fixtures are laid out around the gym's today, never the runner's.
  today = await must<string>(
    admin.rpc("gym_today", { p_gym: gymId }),
    "Gym today",
  );
  const utcDay = new Date(`${today}T12:00:00Z`).getUTCDay();
  weekday = utcDay === 0 ? 7 : utcDay;

  const trainers = await must(
    admin
      .from("trainers")
      .insert(
        ["E2E Julija", "E2E Tamara", "E2E Milena"].map((full_name) => ({
          gym_id: gymId,
          full_name,
        })),
      )
      .select("id, full_name")
      .returns<{ id: string; full_name: string }[]>(),
    "Test trainers",
  );
  const trainer = (name: string) =>
    trainers.find((row) => row.full_name === name)!.id;
  const julija = trainer("E2E Julija");
  const tamara = trainer("E2E Tamara");
  const milena = trainer("E2E Milena");

  const programs = await must(
    admin
      .from("programs")
      .insert([
        { gym_id: gymId, name: "E2E Personalni trening", kind: "personal" },
        { gym_id: gymId, name: "E2E Grupni trening", kind: "group" },
      ])
      .select("id, kind")
      .returns<{ id: string; kind: string }[]>(),
    "Test programs",
  );
  const personalProgram = programs.find((row) => row.kind === "personal")!.id;
  const groupProgram = programs.find((row) => row.kind === "group")!.id;
  // BR-023: Julija and Tamara train Personalni, Milena only group classes.
  await must(
    admin
      .from("trainer_programs")
      .insert([
        { gym_id: gymId, trainer_id: julija, program_id: personalProgram },
        { gym_id: gymId, trainer_id: tamara, program_id: personalProgram },
        { gym_id: gymId, trainer_id: milena, program_id: groupProgram },
      ])
      .select("trainer_id"),
    "Test assignments",
  );
  await must(
    admin
      .from("class_slots")
      .insert({
        gym_id: gymId,
        program_id: groupProgram,
        trainer_id: milena,
        weekday,
        starts_at: "08:00",
        is_active: true,
      })
      .select("id"),
    "Test class slot",
  );

  const plans = await must(
    admin
      .from("plans")
      .insert([
        {
          gym_id: gymId,
          name: "E2E Personalni",
          kind: "personal",
          duration_value: 1,
          duration_unit: "month",
          price: null,
          covers_gym: false,
          covers_group: false,
          covers_personal: true,
          requires_trainer: true,
          sort_order: 1,
        },
        {
          gym_id: gymId,
          name: "E2E Grupni",
          kind: "group",
          duration_value: 1,
          duration_unit: "month",
          price: 69,
          covers_gym: false,
          covers_group: true,
          covers_personal: false,
          group_session_limit: 12,
          requires_trainer: true,
          sort_order: 2,
        },
      ])
      .select("id, kind")
      .returns<{ id: string; kind: string }[]>(),
    "Test plans",
  );
  const personal = plans.find((row) => row.kind === "personal")!.id;
  const grupni = plans.find((row) => row.kind === "group")!.id;

  const members = await must(
    admin
      .from("members")
      .insert(
        [
          ["Ana", "Personalna"],
          ["Iva", "Potrosila"],
          ["Tea", "Grupna"],
          ["Stari", "Istekao"],
        ].map(([first_name, last_name], index) => ({
          gym_id: gymId,
          member_number: index + 1,
          first_name,
          last_name,
          phone: `+3826755600${index + 1}`,
          email: `personalni${index + 1}@e2e.invalid`,
          date_of_birth: "1995-03-05",
          created_by: owner.id,
        })),
      )
      .select("id, member_number")
      .returns<{ id: string; member_number: number }[]>(),
    "Test members",
  );
  for (const row of members) memberIds.set(row.member_number, row.id);
  const member = (number: number) => memberIds.get(number)!;

  // 1 Personalni with Julija (12 sessions, 2 used) and the next one, starting after it;
  // 2 Personalni with Julija, all 4 sessions used; 3 Grupni with Milena at 08:00;
  // 4 Personalni with Julija that expired yesterday.
  const sales: {
    key: string;
    number: number;
    plan: string;
    trainer: string;
    from: number;
    to: number;
    sessions: number | null;
    amount: number;
  }[] = [
    {
      key: "ana",
      number: 1,
      plan: personal,
      trainer: julija,
      from: -3,
      to: 27,
      sessions: 12,
      amount: 80,
    },
    {
      key: "ana-next",
      number: 1,
      plan: personal,
      trainer: julija,
      from: 28,
      to: 58,
      sessions: 8,
      amount: 100,
    },
    {
      key: "iva",
      number: 2,
      plan: personal,
      trainer: julija,
      from: -10,
      to: 20,
      sessions: 4,
      amount: 45,
    },
    {
      key: "tea",
      number: 3,
      plan: grupni,
      trainer: milena,
      from: -3,
      to: 27,
      sessions: null,
      amount: 69,
    },
    {
      key: "stari",
      number: 4,
      plan: personal,
      trainer: julija,
      from: -31,
      to: -1,
      sessions: 8,
      amount: 80,
    },
  ];
  const memberships = await must(
    admin
      .from("memberships")
      .insert(
        sales.map((sale) => ({
          gym_id: gymId,
          member_id: member(sale.number),
          plan_id: sale.plan,
          trainer_id: sale.trainer,
          class_time: sale.plan === grupni ? "08:00" : null,
          start_date: addDays(today, sale.from),
          end_date: addDays(today, sale.to),
          start_reason: `E2E ${sale.key}`,
          covers_gym: false,
          covers_group: sale.plan === grupni,
          covers_personal: sale.plan === personal,
          group_session_limit: sale.plan === grupni ? 12 : null,
          personal_session_limit: sale.plan === personal ? sale.sessions : null,
          is_backdated: true,
          created_by: owner.id,
        })),
      )
      .select("id, start_reason")
      .returns<{ id: string; start_reason: string }[]>(),
    "Test memberships",
  );
  const membership = (key: string) =>
    memberships.find((row) => row.start_reason === `E2E ${key}`)!.id;

  await must(
    admin
      .from("payments")
      .insert(
        sales.map((sale) => ({
          gym_id: gymId,
          kind: "membership",
          membership_id: membership(sale.key),
          member_id: member(sale.number),
          plan_id: sale.plan,
          amount: sale.amount,
          method: "cash",
          paid_on: addDays(today, Math.min(sale.from, 0)),
          is_backdated: true,
          created_by: owner.id,
        })),
      )
      .select("id"),
    "Test payments",
  );

  // BR-054: Ana trained twice with Julija, Iva four times; every visit is closed.
  const visit = (number: number, key: string, daysAgo: number) => {
    const at = new Date(Date.now() - daysAgo * 86_400_000);
    return {
      gym_id: gymId,
      member_id: member(number),
      membership_id: membership(key),
      visit_type: "personal",
      trainer_id: julija,
      is_unpaid: false,
      checked_in_at: at.toISOString(),
      checked_out_at: new Date(at.getTime() + 3_600_000).toISOString(),
      checked_in_by: receptionist.id,
    };
  };
  await must(
    admin
      .from("visits")
      .insert([
        visit(1, "ana", 2),
        visit(1, "ana", 1),
        visit(2, "iva", 8),
        visit(2, "iva", 6),
        visit(2, "iva", 4),
        visit(2, "iva", 2),
      ])
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

test("D-105: reception opens Personalni and sees each trainer's personal members", async ({
  page,
}) => {
  await signIn(page, receptionist);
  await page.goto("/trainers");
  const tabs = page.getByRole("navigation", { name: "Vrsta treninga" });

  // Grupni stays the default and lists the group roster as before (D-72).
  await expect(tabs.getByRole("link", { name: "Grupni" })).toHaveAttribute(
    "aria-current",
    "page",
  );
  await expect(
    page.getByText(
      "Članovi sa grupnom članarinom koja važi danas, po treneru i fiksnom terminu.",
    ),
  ).toBeVisible();
  await expect(page.getByRole("region", { name: "E2E Milena" })).toContainText(
    "#3 Tea Grupna",
  );
  await expect(page.locator("main")).not.toContainText("Ana Personalna");

  await tabs.getByRole("link", { name: "Personalni" }).click();
  await expect(page).toHaveURL(/\/trainers\?tab=personalni$/);
  await expect(tabs.getByRole("link", { name: "Personalni" })).toHaveAttribute(
    "aria-current",
    "page",
  );
  await expect(
    page.getByText(
      "Članovi sa personalnom članarinom koja važi danas ili počinje kasnije, po treneru.",
    ),
  ).toBeVisible();

  // Julija: Ana's current membership and the next one, then Iva with every session used.
  const julija = page.getByRole("region", { name: "E2E Julija" });
  await expect(julija).toContainText("Članova: 2");
  for (const header of [
    "#",
    "Član",
    "Datum uplate",
    "Važi do",
    "Preostalo termina",
  ])
    await expect(
      julija.getByRole("columnheader", { name: header, exact: true }),
    ).toBeVisible();
  const rows = julija.locator("tbody tr");
  await expect(rows).toHaveCount(3);
  await expect(rows.nth(0)).toContainText("#1 Ana Personalna");
  await expect(rows.nth(0)).toContainText(shown(addDays(today, -3)));
  await expect(rows.nth(0)).toContainText(shown(addDays(today, 27)));
  await expect(rows.nth(0)).toContainText("10 od 12");
  await expect(rows.nth(0)).not.toContainText("Počinje");
  await expect(rows.nth(1)).toContainText("#1 Ana Personalna");
  await expect(rows.nth(1)).toContainText(
    `Počinje ${shown(addDays(today, 28))}.`,
  );
  await expect(rows.nth(1)).toContainText(shown(addDays(today, 58)));
  await expect(rows.nth(1)).toContainText("8 od 8");
  await expect(rows.nth(2)).toContainText("#2 Iva Potrosila");
  await expect(rows.nth(2)).toContainText("0 od 4");
  // BR-027a: an expired membership and a group one are not on the Personalni tab.
  await expect(page.locator("main")).not.toContainText("Stari Istekao");
  await expect(page.locator("main")).not.toContainText("Tea Grupna");
  await expect(page.getByRole("region", { name: "E2E Milena" })).toHaveCount(0);

  // BR-023: Tamara trains Personalni and is listed with no members.
  await expect(page.getByRole("region", { name: "E2E Tamara" })).toContainText(
    "Nema personalnih članova.",
  );

  // BR-157: no amount reaches reception.
  await expect(page.getByText("Cijena po članu (€)")).toHaveCount(0);
  await expect(page.getByText(/UKUPNO/)).toHaveCount(0);
  await expect(page.locator("main")).not.toContainText("80,00");

  // The member opens their profile (S-07).
  await julija.getByRole("link", { name: "#2 Iva Potrosila" }).click();
  await expect(page).toHaveURL(new RegExp(`/members/${memberIds.get(2)}$`));
});

test("D-105: the owner also sees each personal amount and the trainer's total", async ({
  page,
}) => {
  await signIn(page, owner);
  await page.goto("/trainers?tab=personalni");
  const julija = page.getByRole("region", { name: "E2E Julija" });
  await expect(
    julija.getByRole("columnheader", { name: "Cijena po članu (€)" }),
  ).toBeVisible();
  const rows = julija.locator("tbody tr");
  await expect(rows.nth(0)).toContainText("80,00 €");
  await expect(rows.nth(1)).toContainText("100,00 €");
  await expect(rows.nth(2)).toContainText("45,00 €");
  // 80 + 100 + 45: every listed membership, the next one included.
  await expect(julija.locator("tfoot")).toContainText("UKUPNO – E2E Julija");
  await expect(julija.locator("tfoot")).toContainText("225,00 €");
  await expect(
    page.getByRole("region", { name: "E2E Tamara" }).locator("tfoot"),
  ).toContainText("0,00 €");
});
