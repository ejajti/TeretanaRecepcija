import { describe, expect, it } from "vitest";
import {
  adjustReasonLabel,
  reasonsFor,
  signedQuantity,
} from "@/features/storage/adjust";
import {
  adjustSchema,
  saleSchema,
  stockInSchema,
} from "@/features/storage/schemas";
import { getErrorMessage } from "@/lib/errors";
import { me } from "@/lib/i18n/me";

const productId = "11111111-1111-4111-8111-111111111111";

describe("stockInSchema (BR-141, D-55, D-95)", () => {
  // D-95: the owner's expense form (BR-133) without the category, as FormData sends it.
  const base = {
    productId,
    quantity: "24",
    description: "",
    spentOn: "",
    method: "cash",
    fromTill: true,
    supplier: "",
    invoice: "",
    vat: "unset",
  };
  it("accepts €0.01 and keeps the price as a decimal string", () => {
    expect(stockInSchema.parse({ ...base, unitCost: "0,01" }).unitCost).toBe(
      "0.01",
    );
    expect(stockInSchema.parse({ ...base, unitCost: "0,35" }).unitCost).toBe(
      "0.35",
    );
  });
  it("refuses a free or negative delivery with the D-55 message", () => {
    for (const unitCost of ["0", "0,00", "-1", ""])
      expect(
        stockInSchema.safeParse({ ...base, unitCost }).error?.issues[0]
          ?.message,
      ).toBe(me.errors.E_STOCK_COST_INVALID);
  });
  it("needs 1–10,000 units and a method", () => {
    expect(
      stockInSchema.safeParse({ ...base, unitCost: "1", quantity: "0" })
        .success,
    ).toBe(false);
    expect(
      stockInSchema.safeParse({ ...base, unitCost: "1", quantity: "10001" })
        .success,
    ).toBe(false);
    expect(
      stockInSchema.safeParse({ ...base, unitCost: "1", method: "" }).success,
    ).toBe(false);
  });
  it("D-95: an empty description and date are left to the database", () => {
    const value = stockInSchema.parse({ ...base, unitCost: "0,35" });
    expect(value.description).toBe("");
    expect(value.spentOn).toBeNull();
    expect(
      stockInSchema.parse({ ...base, unitCost: "1", spentOn: "2026-09-28" })
        .spentOn,
    ).toBe("2026-09-28");
  });
  it("D-95: refuses a one-letter description and an overlong supplier or invoice", () => {
    const issue = (patch: Record<string, string>) =>
      stockInSchema.safeParse({ ...base, unitCost: "1", ...patch }).error
        ?.issues[0]?.message;
    expect(issue({ description: "X" })).toBe(me.finance.descriptionInvalid);
    expect(issue({ description: "x".repeat(201) })).toBe(
      me.finance.descriptionInvalid,
    );
    expect(issue({ supplier: "a".repeat(101) })).toBe(
      me.finance.supplierInvalid,
    );
    expect(issue({ invoice: "1".repeat(51) })).toBe(me.finance.invoiceInvalid);
  });
  it("BR-133: from the till is cash only; outside it any method", () => {
    expect(
      stockInSchema.safeParse({ ...base, unitCost: "1", method: "card" })
        .success,
    ).toBe(false);
    for (const method of ["cash", "card", "none"])
      expect(
        stockInSchema.safeParse({
          ...base,
          unitCost: "1",
          method,
          fromTill: false,
        }).success,
      ).toBe(true);
  });
});

describe("saleSchema (BR-142)", () => {
  it("needs a whole quantity of at least one and a method", () => {
    expect(
      saleSchema.parse({ productId, quantity: "2", method: "card" }),
    ).toEqual({ productId, quantity: 2, method: "card" });
    expect(
      saleSchema.safeParse({ productId, quantity: "0", method: "cash" })
        .success,
    ).toBe(false);
    expect(
      saleSchema.safeParse({ productId, quantity: "1.5", method: "cash" })
        .success,
    ).toBe(false);
    expect(
      saleSchema.safeParse({ productId, quantity: "1", method: "" }).success,
    ).toBe(false);
  });
});

describe("adjustSchema (D-103, BR-145)", () => {
  // S-13 Poravnanje stanja, as FormData sends it: E26 counts 5 of 10 bags.
  const base = {
    productId,
    counted: "5",
    expected: "10",
    reason: "damaged",
    note: "",
  };
  const issue = (value: Record<string, string>) =>
    adjustSchema.safeParse({ ...base, ...value }).error?.issues[0]?.message;

  it("accepts E26: five of ten bags, damaged, with the note trimmed", () => {
    expect(adjustSchema.parse({ ...base, note: "  Pukle kesice " })).toEqual({
      productId,
      counted: 5,
      expected: 10,
      reason: "damaged",
      note: "Pukle kesice",
    });
  });
  it("counts 0–10,000 whole units, and an empty field is not a count of zero", () => {
    expect(adjustSchema.parse({ ...base, counted: "0" }).counted).toBe(0);
    for (const counted of ["", "  ", "-1", "10001", "2.5", "pet"])
      expect(issue({ counted })).toBe(me.storage.adjustCountedInvalid);
  });
  it("refuses a count equal to the stock level", () => {
    expect(issue({ counted: "10" })).toBe(me.storage.adjustSame);
  });
  it("offers goods found only a stock count or Ostalo", () => {
    for (const reason of ["damaged", "expired", "internal_use"])
      expect(issue({ counted: "12", reason })).toBe(
        me.storage.adjustReasonInvalid,
      );
    expect(
      adjustSchema.safeParse({ ...base, counted: "12", reason: "count" })
        .success,
    ).toBe(true);
    expect(issue({ reason: "stolen" })).toBe(me.storage.adjustReasonInvalid);
  });
  it("needs a note of 3–200 characters for Ostalo, and allows one up to 200", () => {
    expect(issue({ reason: "other", note: " ab " })).toBe(
      me.storage.adjustNoteRequired,
    );
    expect(
      adjustSchema.safeParse({ ...base, reason: "other", note: "Popis" })
        .success,
    ).toBe(true);
    expect(issue({ note: "a".repeat(201) })).toBe(me.storage.adjustNoteInvalid);
  });
  it("counts the note in characters, as the database does", () => {
    // Two emoji are four UTF-16 units but two characters: too short for Ostalo.
    expect(issue({ reason: "other", note: "😀😀" })).toBe(
      me.storage.adjustNoteRequired,
    );
    expect(
      adjustSchema.safeParse({ ...base, note: "😀".repeat(200) }).success,
    ).toBe(true);
  });
});

describe("adjustment labels (D-103)", () => {
  it("lists every reason for goods short and two for goods found", () => {
    expect(reasonsFor(-5)).toEqual([
      "damaged",
      "expired",
      "internal_use",
      "count",
      "other",
    ]);
    expect(reasonsFor(2)).toEqual(["count", "other"]);
  });
  it("names a stock count by its direction", () => {
    expect(adjustReasonLabel("count", -5)).toBe("Manjak pri popisu");
    expect(adjustReasonLabel("count", 2)).toBe("Višak pri popisu");
    expect(adjustReasonLabel("internal_use", -1)).toBe("Potrošeno u teretani");
  });
  it("writes the sign of a difference", () => {
    expect(signedQuantity(-5)).toBe("-5");
    expect(signedQuantity(2)).toBe("+2");
    expect(signedQuantity(0)).toBe("0");
  });
  it("names the stock level now when the count no longer matches", () => {
    expect(getErrorMessage("E_STOCK_CHANGED", { qty: "9" })).toBe(
      "Stanje se u međuvremenu promijenilo (sada: 9). Prebrojte ponovo.",
    );
  });
});
