import { expect, test, type Browser, type Page } from "@playwright/test";
import {
  adminClient,
  createTestGym,
  createTestStaff,
  deleteTestGym,
  suffix,
  type TestStaff,
} from "./fixtures";

// D-104 (BR-133, BR-151, BR-158): Trošak za mjesec through the screens. E27: the owner
// pays last month's electricity today; it is last month's cost in Bilans uspjeha and
// this month's payment in Novčani tok, and S-17 lists it today with its month. The desk
// chooses the month too, on a bill paid from the till.
test.describe.configure({ mode: "serial" });

const PASSWORD = "mjesectroskalozinka1";
const MONTHS = [
  "januar",
  "februar",
  "mart",
  "april",
  "maj",
  "jun",
  "jul",
  "avgust",
  "septembar",
  "oktobar",
  "novembar",
  "decembar",
];

let gymId: string;
let owner: TestStaff;
let receptionist: TestStaff;
let today: string;
let lastMonth: string;

/** "septembar 2026" for yyyy-mm-dd. */
function monthName(date: string): string {
  return `${MONTHS[Number(date.slice(5, 7)) - 1]} ${date.slice(0, 4)}`;
}

test.beforeAll(async ({}, workerInfo) => {
  gymId = await createTestGym(
    `${workerInfo.project.name}-cost-month-${suffix()}`,
  );
  owner = await createTestStaff(gymId, {
    role: "owner",
    fullName: "E2E Vlasnik Računa",
    password: PASSWORD,
  });
  receptionist = await createTestStaff(gymId, {
    role: "receptionist",
    fullName: "E2E Recepcija Računa",
    password: PASSWORD,
  });
  const admin = adminClient();
  const category = await admin
    .from("expense_categories")
    .insert({ gym_id: gymId, name: "E2E Struja" });
  if (category.error) throw new Error(category.error.message);
  const { data } = await admin.rpc("gym_today", { p_gym: gymId });
  today = data as string;
  const date = new Date(
    Date.UTC(Number(today.slice(0, 4)), Number(today.slice(5, 7)) - 2, 1),
  );
  lastMonth = date.toISOString().slice(0, 10);
});

test.afterAll(async () => {
  await deleteTestGym(gymId);
});

async function signIn(browser: Browser, staff: TestStaff): Promise<Page> {
  const page = await (await browser.newContext()).newPage();
  await page.goto("/login");
  await page.getByLabel("Korisničko ime ili email").fill(staff.identifier);
  await page.getByLabel("Lozinka", { exact: true }).fill(PASSWORD);
  await page.getByRole("button", { name: "Prijavi se" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/login"));
  return page;
}

async function expense(description: string) {
  const { data } = await adminClient()
    .from("expenses")
    .select("spent_on, cost_month, paid_from_till, amount::text")
    .eq("gym_id", gymId)
    .eq("description", description)
    .single();
  return data;
}

test("E27: last month's electricity paid today", async ({ browser }) => {
  const page = await signIn(browser, owner);
  await page.goto("/finance/expenses?period=month");
  await page.getByRole("button", { name: "Novi trošak" }).click();
  const dialog = page.getByRole("dialog");
  const month = dialog.getByLabel("Trošak za mjesec");
  // The month paid first, then the twelve before it.
  await expect(month.locator("option")).toHaveCount(13);
  await expect(month).toHaveValue(`${today.slice(0, 7)}-01`);
  await expect(month.locator("option").first()).toHaveText(monthName(today));
  await expect(dialog.getByLabel("Datum plaćanja")).toHaveValue(today);

  await dialog
    .getByLabel("Kategorija", { exact: true })
    .selectOption({ label: "E2E Struja" });
  await dialog.getByLabel("Opis").fill("E2E struja za prošli mjesec");
  await dialog.getByLabel("Iznos (€)").fill("120");
  await dialog.getByLabel("Način", { exact: true }).selectOption("card");
  await month.selectOption(lastMonth);
  await dialog.getByRole("button", { name: "Sačuvaj" }).click();
  await expect(page.getByText("Trošak je sačuvan.")).toBeVisible();

  // S-17 lists it on the day paid, with the month it is for.
  const row = page.getByRole("row", { name: /E2E struja za prošli mjesec/ });
  await expect(row).toContainText(`Za mjesec: ${monthName(lastMonth)}`);
  expect(await expense("E2E struja za prošli mjesec")).toEqual({
    spent_on: today,
    cost_month: lastMonth,
    paid_from_till: false,
    amount: "120.00",
  });

  // Last month: the cost, and no payment.
  await page.goto("/finance?period=last_month");
  const statement = page.locator("section", {
    has: page.getByRole("heading", { name: "Bilans uspjeha" }),
  });
  const cash = page.locator("section", {
    has: page.getByRole("heading", { name: "Novčani tok" }),
  });
  await expect(
    statement.getByRole("row", { name: /^E2E Struja/ }),
  ).toContainText("120,00 €");
  await expect(statement.getByRole("row", { name: /^Profit/ })).toContainText(
    "-120,00 €",
  );
  await expect(
    cash.getByRole("row", { name: /^Ostala plaćanja/ }),
  ).toContainText("0,00 €");

  // This month: the payment, and no cost.
  await page.goto("/finance?period=month");
  await expect(statement.getByText("Nema operativnih troškova.")).toBeVisible();
  await expect(
    cash.getByRole("row", { name: /^Ostala plaćanja/ }),
  ).toContainText("120,00 €");
  await page.context().close();
});

test("D-104: the desk pays last month's bill from the till", async ({
  browser,
}) => {
  const page = await signIn(browser, receptionist);
  await page.waitForURL(/\/reception/);
  await page.getByRole("button", { name: "Počni rad" }).click();
  await page.getByRole("button", { name: "Trošak" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog.getByRole("checkbox", { name: /Iz kase/ })).toBeChecked();
  await expect(dialog.getByLabel("Datum plaćanja")).toBeDisabled();
  await dialog.getByLabel("Kategorija").selectOption({ label: "E2E Struja" });
  await dialog.getByLabel("Opis").fill("E2E voda za prošli mjesec");
  await dialog.getByLabel("Iznos (€)").fill("15");
  await dialog.getByLabel("Trošak za mjesec").selectOption(lastMonth);
  await dialog.getByRole("button", { name: "Sačuvaj" }).click();
  await expect(page.getByText("Trošak je sačuvan.")).toBeVisible();
  expect(await expense("E2E voda za prošli mjesec")).toEqual({
    spent_on: today,
    cost_month: lastMonth,
    paid_from_till: true,
    amount: "15.00",
  });
  await page.context().close();
});
