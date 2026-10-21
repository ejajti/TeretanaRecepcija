import { expect, test, type Browser, type Page } from "@playwright/test";
import {
  adminClient,
  createTestGym,
  createTestStaff,
  deleteTestGym,
  suffix,
  type TestStaff,
} from "./fixtures";

// D-103 (BR-145, P-45): Poravnanje stanja through the screens. A receptionist has no
// [Poravnaj stanje]; the manager counts five of ten bags of whey (E26) and is stopped
// when the stock changes while counting; the owner sees Manjak robe in the statement and
// on S-20, and voids the adjustment, which puts the five bags back.
test.describe.configure({ mode: "serial" });

const PASSWORD = "poravnanjelozinka1";

let gymId: string;
let owner: TestStaff;
let manager: TestStaff;
let receptionist: TestStaff;
let productId: string;

test.beforeAll(async ({}, workerInfo) => {
  gymId = await createTestGym(`${workerInfo.project.name}-adjust-${suffix()}`);
  owner = await createTestStaff(gymId, {
    role: "owner",
    fullName: "E2E Vlasnik Popisa",
    password: PASSWORD,
  });
  manager = await createTestStaff(gymId, {
    role: "manager",
    fullName: "E2E Menadžer Popisa",
    password: PASSWORD,
  });
  receptionist = await createTestStaff(gymId, {
    role: "receptionist",
    fullName: "E2E Recepcija Popisa",
    password: PASSWORD,
  });
  const admin = adminClient();
  // E26: whey bought at €28 and sold at €41, ten bags in stock.
  const product = await admin
    .from("products")
    .insert({
      gym_id: gymId,
      name: "E2E Whey",
      current_purchase_price: 28,
      sale_price: 41,
    })
    .select("id")
    .single<{ id: string }>();
  if (product.error || !product.data) throw new Error(product.error?.message);
  productId = product.data.id;
  await receive(10);
});

test.afterAll(async () => {
  await deleteTestGym(gymId);
});

/** Goods arriving beside the screens, as another desk's Nova roba would. */
async function receive(quantity: number) {
  const { error } = await adminClient().from("stock_movements").insert({
    gym_id: gymId,
    product_id: productId,
    type: "in",
    quantity,
    unit_cost: 28,
    created_by: owner.id,
  });
  if (error) throw new Error(error.message);
}

async function signIn(browser: Browser, staff: TestStaff): Promise<Page> {
  const page = await (await browser.newContext()).newPage();
  await page.goto("/login");
  await page.getByLabel("Korisničko ime ili email").fill(staff.identifier);
  await page.getByLabel("Lozinka", { exact: true }).fill(PASSWORD);
  await page.getByRole("button", { name: "Prijavi se" }).click();
  await page.waitForURL((url) => !url.pathname.startsWith("/login"));
  return page;
}

async function openStorage(page: Page) {
  await page.goto("/storage");
  await expect(page.getByRole("heading", { name: "Magacin" })).toBeVisible();
}

async function adjustments() {
  const { data } = await adminClient()
    .from("stock_movements")
    .select(
      "quantity, counted_qty, adjust_reason, note, unit_cost::text, shift_id, voided_at",
    )
    .eq("product_id", productId)
    .eq("type", "adjust");
  return data ?? [];
}

test("P-45: a receptionist does not adjust the stock", async ({ browser }) => {
  const page = await signIn(browser, receptionist);
  await openStorage(page);
  await expect(
    page.getByRole("button", { name: "Prodaja E2E Whey" }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Poravnaj stanje E2E Whey" }),
  ).toHaveCount(0);
  await page.context().close();
});

test("E26: the manager counts five of ten bags", async ({ browser }) => {
  const page = await signIn(browser, manager);
  await openStorage(page);
  await page.getByRole("button", { name: "Poravnaj stanje E2E Whey" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog.getByTestId("adjust-stock")).toHaveText(
    "Stanje u aplikaciji: 10",
  );
  const save = dialog.getByRole("button", { name: "Sačuvaj" });
  await expect(save).toBeDisabled();

  // Goods found: only a stock count or Ostalo, and the reminder about Nova roba.
  const counted = dialog.getByLabel("Prebrojano stanje");
  const reason = dialog.getByLabel("Razlog");
  await counted.fill("12");
  await expect(dialog.getByText("Razlika: +2 (višak)")).toBeVisible();
  await expect(dialog.getByText(/unesite je preko „Nova roba“/)).toBeVisible();
  await expect(reason.locator("option")).toHaveText([
    "Višak pri popisu",
    "Ostalo",
  ]);
  await counted.fill("10");
  await expect(
    dialog.getByText("Prebrojano stanje je isto kao stanje u aplikaciji."),
  ).toBeVisible();
  await expect(save).toBeDisabled();

  // Goods short: every reason.
  await counted.fill("5");
  await expect(dialog.getByText("Razlika: -5 (manjak)")).toBeVisible();
  await expect(dialog.getByText(/unesite je preko „Nova roba“/)).toHaveCount(0);
  await expect(reason.locator("option")).toHaveText([
    "Oštećeno",
    "Istekao rok",
    "Potrošeno u teretani",
    "Manjak pri popisu",
    "Ostalo",
  ]);
  // Ostalo needs its note.
  await reason.selectOption("other");
  await save.click();
  await expect(
    dialog.getByText("Za razlog „Ostalo“ upišite napomenu (3–200 znakova)."),
  ).toBeVisible();
  await reason.selectOption("damaged");
  await dialog.getByLabel("Napomena").fill("Pukle kesice");
  await save.click();
  await expect(page.getByText("Stanje je poravnano.")).toBeVisible();
  await expect(page.getByTestId("stock-E2E Whey")).toHaveText("5");

  expect(await adjustments()).toEqual([
    {
      quantity: -5,
      counted_qty: 5,
      adjust_reason: "damaged",
      note: "Pukle kesice",
      unit_cost: "28.00",
      shift_id: null,
      voided_at: null,
    },
  ]);
  await page.context().close();
});

test("BR-145: a count made while the stock changed is counted again", async ({
  browser,
}) => {
  const page = await signIn(browser, manager);
  await openStorage(page);
  await page.getByRole("button", { name: "Poravnaj stanje E2E Whey" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog.getByTestId("adjust-stock")).toHaveText(
    "Stanje u aplikaciji: 5",
  );
  // One more bag arrives at another desk while the shelf is counted.
  await receive(1);
  await dialog.getByLabel("Prebrojano stanje").fill("3");
  await dialog.getByRole("button", { name: "Sačuvaj" }).click();
  await expect(
    dialog.getByText(
      "Stanje se u međuvremenu promijenilo (sada: 6). Prebrojte ponovo.",
    ),
  ).toBeVisible();
  await expect(dialog.getByTestId("adjust-stock")).toHaveText(
    "Stanje u aplikaciji: 6",
  );
  await dialog.getByRole("button", { name: "Otkaži" }).click();
  expect(await adjustments()).toHaveLength(1);
  await page.context().close();
});

test("E26 for the owner: Manjak robe, S-20 and the void", async ({
  browser,
}) => {
  const page = await signIn(browser, owner);

  // S-16: the five bags are a cost of today; no money moved (BR-152, BR-158).
  await page.goto("/finance?period=today");
  const statement = page.locator("section", {
    has: page.getByRole("heading", { name: "Bilans uspjeha" }),
  });
  await expect(
    statement.getByRole("row", { name: /^Manjak robe/ }),
  ).toContainText("140,00 €");
  await expect(
    statement.getByRole("row", { name: /^Bruto dobit/ }),
  ).toContainText("-140,00 €");
  await expect(statement.getByRole("row", { name: /^Profit/ })).toContainText(
    "-140,00 €",
  );
  const cash = page.locator("section", {
    has: page.getByRole("heading", { name: "Novčani tok" }),
  });
  await expect(
    cash.getByRole("row", { name: /^Neto promjena novca/ }),
  ).toContainText("0,00 €");
  // BR-159: six bags left at €28.
  await expect(cash).toContainText("168,00 €");

  // S-20: the product row and the list of adjustments.
  await page.goto("/finance/storage?period=today");
  const row = page
    .locator("section", {
      has: page.getByRole("heading", { name: "Magacin", exact: true }),
    })
    .getByRole("row", { name: /^E2E Whey/ });
  await expect(row.getByRole("cell")).toHaveText([
    "E2E Whey",
    "28,00 €",
    "41,00 €",
    "11",
    "308,00 €",
    "0",
    "0,00 €",
    "0,00 €",
    "0,00 €",
    "—",
    "-5",
    "140,00 €",
    "6",
    "168,00 €",
  ]);
  const list = page.getByRole("table", { name: "Poravnanja stanja" });
  const entry = list.getByRole("row", { name: /E2E Whey/ });
  await expect(entry.getByRole("cell").nth(1)).toHaveText("E2E Whey");
  await expect(entry.getByRole("cell").nth(2)).toHaveText("10");
  await expect(entry.getByRole("cell").nth(3)).toHaveText("5");
  await expect(entry.getByRole("cell").nth(4)).toHaveText("-5");
  await expect(entry.getByRole("cell").nth(5)).toHaveText(
    "OštećenoPukle kesice",
  );
  await expect(entry.getByRole("cell").nth(6)).toHaveText("140,00 €");
  await expect(entry.getByRole("cell").nth(7)).toHaveText(manager.fullName);

  // BR-095: the owner voids it; the bags are back and Manjak robe is gone.
  await entry.getByRole("button", { name: "Poništi" }).click();
  const voiding = page.getByRole("dialog");
  await voiding.getByLabel("Razlog").fill("Pogrešno prebrojano");
  await voiding.getByRole("button", { name: "Poništi" }).click();
  await expect(page.getByText("Poništeno: Pogrešno prebrojano")).toBeVisible();
  await expect(row.getByRole("cell").nth(10)).toHaveText("0");
  await expect(row.getByRole("cell").nth(12)).toHaveText("11");

  await openStorage(page);
  await expect(page.getByTestId("stock-E2E Whey")).toHaveText("11");
  await page.context().close();
});

test("D-103: voiding a count made before another one warns", async ({
  browser,
}) => {
  // Two counts of the same bag, a minute apart: 11 → 10, then 10 → 9.
  const minutesAgo = (minutes: number) =>
    new Date(Date.now() - minutes * 60_000).toISOString();
  const { error } = await adminClient()
    .from("stock_movements")
    .insert([
      {
        gym_id: gymId,
        product_id: productId,
        type: "adjust",
        quantity: -1,
        unit_cost: 28,
        counted_qty: 10,
        adjust_reason: "count",
        created_by: manager.id,
        created_at: minutesAgo(2),
      },
      {
        gym_id: gymId,
        product_id: productId,
        type: "adjust",
        quantity: -1,
        unit_cost: 28,
        counted_qty: 9,
        adjust_reason: "count",
        created_by: manager.id,
        created_at: minutesAgo(1),
      },
    ]);
  if (error) throw new Error(error.message);

  const page = await signIn(browser, owner);
  await page.goto("/finance/storage?period=today");
  const list = page.getByRole("table", { name: "Poravnanja stanja" });
  const warning =
    "Ovaj proizvod je poslije ovog poravnanja ponovo prebrojan. Ako ga poništite, stanje se više neće slagati sa posljednjim brojanjem.";

  const older = list
    .getByRole("row")
    .filter({ has: page.getByRole("cell", { name: "11", exact: true }) });
  await older.getByRole("button", { name: "Poništi" }).click();
  await expect(page.getByRole("dialog").getByRole("alert")).toHaveText(warning);
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Otkaži" })
    .click();

  const newer = list
    .getByRole("row")
    .filter({ has: page.getByRole("cell", { name: "9", exact: true }) });
  await newer.getByRole("button", { name: "Poništi" }).click();
  await expect(page.getByRole("dialog")).toBeVisible();
  await expect(page.getByRole("dialog").getByRole("alert")).toHaveCount(0);
  await page
    .getByRole("dialog")
    .getByRole("button", { name: "Otkaži" })
    .click();
  await page.context().close();
});
