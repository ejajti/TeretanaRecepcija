import type { Metadata } from "next";
import { PersonalRoster } from "@/features/trainers/components/personal-roster";
import { TrainerRoster } from "@/features/trainers/components/trainer-roster";
import {
  TrainerTabs,
  type TrainerTab,
} from "@/features/trainers/components/trainer-tabs";
import {
  buildPersonalRoster,
  type PersonalRosterData,
} from "@/features/trainers/personal-roster";
import { buildRoster, type RosterData } from "@/features/trainers/roster";
import { requireStaff } from "@/lib/auth";
import { getErrorMessage } from "@/lib/errors";
import { me } from "@/lib/i18n/me";
import { rpcCode } from "@/lib/rpc";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: `${me.trainerRoster.title} — ${me.app.name}`,
};

type Supabase = Awaited<ReturnType<typeof createClient>>;

/**
 * BR-027, BR-027a and BR-157: the amounts of the listed memberships, asked for only for
 * the owner and the admin through the owner-only fin_roster_prices (doc 08 §2).
 */
async function rosterPrices(supabase: Supabase, memberships: string[]) {
  const { data: rows, error } = await supabase.rpc("fin_roster_prices", {
    p_memberships: memberships,
  });
  if (error) console.error(`fin_roster_prices: ${error.message}`);
  return new Map(
    ((rows ?? []) as { membership_id: string; amount: string }[]).map((row) => [
      row.membership_id,
      row.amount,
    ]),
  );
}

/**
 * S-29 (D-72, D-105): every role. Tab Grupni (`/trainers`) is trainer_roster (BR-027),
 * tab Personalni (`/trainers?tab=personalni`) is personal_roster (BR-027a); only the open
 * tab's roster is read. Neither function ever returns an amount.
 */
export default async function TrainerRosterPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const staff = await requireStaff();
  const isOwner = staff.role === "owner" || staff.role === "admin";
  const query = await searchParams;
  const tab: TrainerTab = query.tab === "personalni" ? "personalni" : "grupni";
  const supabase = await createClient();

  const { data, error } = await supabase.rpc(
    tab === "personalni" ? "personal_roster" : "trainer_roster",
  );

  let content: React.ReactNode;
  if (error) {
    content = (
      <p className="text-sm text-danger">{getErrorMessage(rpcCode(error))}</p>
    );
  } else if (tab === "personalni") {
    const roster = data as PersonalRosterData;
    const prices = isOwner
      ? await rosterPrices(
          supabase,
          roster.members.map((row) => row.membership_id),
        )
      : undefined;
    content = (
      <PersonalRoster
        trainers={buildPersonalRoster(roster, prices)}
        showPrices={isOwner}
      />
    );
  } else {
    const roster = data as RosterData;
    const prices = isOwner
      ? await rosterPrices(
          supabase,
          roster.members.map((row) => row.membership_id),
        )
      : undefined;
    content = (
      <TrainerRoster
        trainers={buildRoster(roster, prices)}
        showPrices={isOwner}
      />
    );
  }

  return (
    <div className="grid grid-cols-1 gap-8">
      <TrainerTabs tab={tab} />
      {content}
    </div>
  );
}
