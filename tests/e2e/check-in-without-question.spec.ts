import { expect, test, type Page } from "@playwright/test";
import {
  adminClient,
  createTestGym,
  createTestStaff,
  deleteTestGym,
  suffix,
  type TestStaff,
} from "./fixtures";

// D-102 (BR-073): reception asks the visit type only when the memberships cover two or
// more types. A Grupni-only member is checked in at their class with one scan, and outside
// it gets an unpaid gym visit; G+T still asks. Everything lives in this test's own gym,
// which afterAll removes.
test.describe.configure({ mode: "serial" });

const PASSWORD = "bezpitanjalozinka1";
const ZONE = "Europe/Podgorica";

let gymId: string;
let receptionist: TestStaff;
let trainerId: string;
let slotNowId: string;
const codes = { inClass: "", outside: "", combo: "" };
const members = { inClass: "", outside: "", combo: "" };

/** BR-030 codes, unique across gyms; the 9 prefix keeps them clear of real batches. */
function cardCode(): string {
  return `9${String(Math.floor(Math.random() * 1e9)).padStart(9, "0")}`;
}

/** The gym's local date, ISO weekday and minutes since midnight right now (BR-001). */
function gymNow() {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-GB", {
      timeZone: ZONE,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      weekday: "short",
      hourCycle: "h23",
    })
      .formatToParts(new Date())
      .map(({ type, value }) => [type, value]),
  );
  return {
    date: `${parts.year}-${parts.month}-${parts.day}`,
    weekday:
      ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].indexOf(parts.weekday) +
      1,
    minutes: Number(parts.hour) * 60 + Number(parts.minute),
  };
}

/** HH:mm:00 for a number of minutes since midnight, wrapping past midnight. */
function clock(minutes: number): string {
  const wrapped = ((minutes % 1440) + 1440) % 1440;
  const hours = String(Math.floor(wrapped / 60)).padStart(2, "0");
  return `${hours}:${String(wrapped % 60).padStart(2, "0")}:00`;
}

function shiftDate(iso: string, days: number): string {
  const date = new Date(`${iso}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

async function must<T>(
  query: PromiseLike<{ data: T | null; error: { message: string } | null }>,
  what: string,
): Promise<T> {
  const { data, error } = await query;
  if (error || data === null)
    throw new Error(`${what} not created: ${error?.message}`);
  return data;
}

test.beforeAll(async ({}, workerInfo) => {
  gymId = await createTestGym(
    `${workerInfo.project.name}-no-question-${suffix()}`,
  );
  receptionist = await createTestStaff(gymId, {
    role: "receptionist",
    fullName: "E2E Recepcija bez pitanja",
    password: PASSWORD,
  });
  const admin = adminClient();
  const now = gymNow();

  const plans = await must(
    admin
      .from("plans")
      .insert([
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
          sort_order: 1,
        },
        {
          gym_id: gymId,
          name: "E2E G+T",
          kind: "combo",
          duration_value: 1,
          duration_unit: "month",
          price: 99,
          covers_gym: true,
          covers_group: true,
          covers_personal: false,
          group_session_limit: 12,
          requires_trainer: true,
          sort_order: 2,
        },
      ])
      .select("id, name")
      .returns<{ id: string; name: string }[]>(),
    "Test plans",
  );
  const grupniId = plans.find((plan) => plan.name === "E2E Grupni")!.id;
  const comboId = plans.find((plan) => plan.name === "E2E G+T")!.id;
  await must(
    admin
      .from("plan_finance")
      .insert(plans.map((plan) => ({ plan_id: plan.id, gym_id: gymId })))
      .select("plan_id"),
    "Test plan finance",
  );

  // Milena's group classes today: one starting now, one in three hours (BR-058a, AS-12).
  const trainer = await must(
    admin
      .from("trainers")
      .insert({ gym_id: gymId, full_name: "E2E Milena" })
      .select("id")
      .single<{ id: string }>(),
    "Test trainer",
  );
  trainerId = trainer.id;
  await must(
    admin
      .from("trainer_finance")
      .insert({ trainer_id: trainerId, gym_id: gymId })
      .select("trainer_id"),
    "Test trainer finance",
  );
  const program = await must(
    admin
      .from("programs")
      .insert({ gym_id: gymId, name: "E2E Grupni trening", kind: "group" })
      .select("id")
      .single<{ id: string }>(),
    "Test program",
  );
  await must(
    admin
      .from("trainer_programs")
      .insert({ gym_id: gymId, trainer_id: trainerId, program_id: program.id })
      .select("trainer_id"),
    "Test assignment",
  );
  const timeNow = clock(now.minutes);
  const timeLater = clock(now.minutes + 180);
  const slots = await must(
    admin
      .from("class_slots")
      .insert(
        [timeNow, timeLater].map((startsAt) => ({
          gym_id: gymId,
          program_id: program.id,
          trainer_id: trainerId,
          weekday: now.weekday,
          starts_at: startsAt,
        })),
      )
      .select("id, starts_at")
      .returns<{ id: string; starts_at: string }[]>(),
    "Test class slots",
  );
  slotNowId = slots.find((slot) => slot.starts_at === timeNow)!.id;

  const created = await must(
    admin
      .from("members")
      .insert(
        [
          [201, "E2E Grupni", "Uterminu"],
          [202, "E2E Grupni", "Vantermina"],
          [203, "E2E GT", "Član"],
        ].map(([number, first, last]) => ({
          gym_id: gymId,
          member_number: number,
          first_name: first,
          last_name: last,
          phone: `+38267102${number}`,
          email: `bezpitanja${number}@e2e.invalid`,
          date_of_birth: "1990-01-01",
          created_by: receptionist.id,
        })),
      )
      .select("id, member_number")
      .returns<{ id: string; member_number: number }[]>(),
    "Test members",
  );
  const byNumber = (number: number) =>
    created.find((member) => member.member_number === number)!.id;
  members.inClass = byNumber(201);
  members.outside = byNumber(202);
  members.combo = byNumber(203);
  await must(
    admin
      .from("member_counters")
      .insert({ gym_id: gymId, last_number: 203 })
      .select("gym_id"),
    "Test member counter",
  );

  // Back-dated fixtures (BR-120): no shift, like the owner's catch-up entries.
  const membership = (memberId: string, planId: string, classTime: string) => ({
    gym_id: gymId,
    member_id: memberId,
    plan_id: planId,
    trainer_id: trainerId,
    class_time: classTime,
    start_date: shiftDate(now.date, -5),
    end_date: shiftDate(now.date, 25),
    start_reason: "E2E",
    covers_gym: planId === comboId,
    covers_group: true,
    covers_personal: false,
    group_session_limit: 12,
    is_backdated: true,
    created_by: receptionist.id,
  });
  await must(
    admin
      .from("memberships")
      .insert([
        membership(members.inClass, grupniId, timeNow),
        membership(members.outside, grupniId, timeLater),
        membership(members.combo, comboId, timeNow),
      ])
      .select("id"),
    "Test memberships",
  );

  const batch = await must(
    admin
      .from("card_batches")
      .insert({ gym_id: gymId, quantity: 3, created_by: receptionist.id })
      .select("id")
      .single<{ id: string }>(),
    "Test card batch",
  );
  codes.inClass = cardCode();
  codes.outside = cardCode();
  codes.combo = cardCode();
  await must(
    admin
      .from("cards")
      .insert(
        (["inClass", "outside", "combo"] as const).map((key) => ({
          gym_id: gymId,
          code: codes[key],
          batch_id: batch.id,
          status: "active",
          member_id: members[key],
          assigned_at: new Date().toISOString(),
        })),
      )
      .select("id"),
    "Test cards",
  );
});

test.afterAll(async () => {
  await deleteTestGym(gymId);
});

/** Signs in and passes the S-03 audio overlay, which a new browser session shows. */
async function openReception(page: Page) {
  await page.goto("/login");
  await page
    .getByLabel("Korisničko ime ili email")
    .fill(receptionist.identifier);
  await page.getByLabel("Lozinka", { exact: true }).fill(PASSWORD);
  await page.getByRole("button", { name: "Prijavi se" }).click();
  await page.waitForURL(/\/reception/);
  await page.getByRole("button", { name: "Počni rad" }).click();
  await expect(
    page.getByRole("heading", { name: "Skenirajte karticu" }),
  ).toBeVisible();
}

/** The USB scanner: ten digits and Enter, typed while no field has focus. */
async function scan(page: Page, code: string) {
  await page.evaluate(() =>
    (document.activeElement as HTMLElement | null)?.blur(),
  );
  await page.keyboard.type(code);
  await page.keyboard.press("Enter");
}

async function visitsOf(memberId: string) {
  const { data } = await adminClient()
    .from("visits")
    .select("visit_type, trainer_id, class_slot_id, is_unpaid")
    .eq("member_id", memberId)
    .returns<
      {
        visit_type: string;
        trainer_id: string | null;
        class_slot_id: string | null;
        is_unpaid: boolean;
      }[]
    >();
  return data ?? [];
}

test("D-102: a Grupni-only member at their class is checked in with one scan", async ({
  page,
}) => {
  await openReception(page);
  await scan(page, codes.inClass);
  const result = page.locator("[data-result=covered]");
  await expect(result).toBeVisible();
  await expect(result.getByText("Grupni: 11 preostalo")).toBeVisible();
  await expect(page.getByRole("heading", { name: /^Prijava:/ })).toHaveCount(0);
  expect(await visitsOf(members.inClass)).toEqual([
    {
      visit_type: "group",
      trainer_id: trainerId,
      class_slot_id: slotNowId,
      is_unpaid: false,
    },
  ]);
});

test("D-102: outside their class it is an unpaid gym visit with the yellow dialog", async ({
  page,
}) => {
  await openReception(page);
  await scan(page, codes.outside);
  const result = page.locator("[data-result=yellow]");
  await expect(result).toBeVisible();
  await expect(
    result.getByText("Članarina nije važeća – neplaćeni dolazak."),
  ).toBeVisible();
  expect(await visitsOf(members.outside)).toEqual([
    {
      visit_type: "gym",
      trainer_id: null,
      class_slot_id: null,
      is_unpaid: true,
    },
  ]);
});

test("D-102: G+T still asks the visit type, and Esc records nothing", async ({
  page,
}) => {
  await openReception(page);
  await scan(page, codes.combo);
  const dialog = page.getByRole("dialog");
  await expect(
    dialog.getByRole("heading", { name: "Prijava: E2E GT Član" }),
  ).toBeVisible();
  await expect(dialog.getByLabel("Teretana")).toBeChecked();
  await expect(dialog.getByLabel("Grupni")).not.toBeChecked();
  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();
  expect(await visitsOf(members.combo)).toEqual([]);
});
