import Link from "next/link";
import { Table, TableWrapper, Td, Th } from "@/components/ui/table";
import { formatDate, formatMoney } from "@/lib/format";
import { me } from "@/lib/i18n/me";
import type {
  PersonalRosterGroup,
  PersonalRosterRow,
} from "../personal-roster";

const t = me.trainerRoster;

/** `6 od 12`, or `Neograničeno` for a membership with no session limit. */
function sessionsLeft(row: PersonalRosterRow) {
  return row.left === null
    ? t.unlimited
    : t.sessionsOf
        .replace("{left}", String(row.left))
        .replace("{limit}", String(row.personal_session_limit));
}

/**
 * S-29 tab Personalni (D-105, BR-027a): one table per trainer of the personal memberships
 * valid today or starting later. The price column and the total are rendered only when
 * `showPrices` is set, and their values come from the owner-only fin_roster_prices
 * (BR-157).
 */
export function PersonalRoster({
  trainers,
  showPrices,
}: {
  trainers: PersonalRosterGroup[];
  showPrices: boolean;
}) {
  const columns = showPrices ? 6 : 5;

  if (trainers.length === 0)
    return <p className="text-sm text-muted-foreground">{t.personalEmpty}</p>;

  return (
    <>
      {trainers.map((trainer) => (
        <section
          key={trainer.trainerId}
          aria-labelledby={`personal-${trainer.trainerId}`}
        >
          <div className="mb-3 flex flex-wrap items-baseline gap-x-3">
            <h2
              id={`personal-${trainer.trainerId}`}
              className="text-lg font-semibold"
            >
              {trainer.trainerName}
            </h2>
            <p className="text-sm text-muted-foreground">
              {t.memberCount.replace("{count}", String(trainer.memberCount))}
            </p>
          </div>
          <TableWrapper>
            <Table>
              <thead>
                <tr>
                  <Th className="w-10">{t.row}</Th>
                  <Th>{t.member}</Th>
                  <Th>{t.paidOn}</Th>
                  <Th>{t.validUntil}</Th>
                  <Th>{t.sessionsLeft}</Th>
                  {showPrices ? (
                    <Th className="text-right">{t.price}</Th>
                  ) : null}
                </tr>
              </thead>
              <tbody>
                {trainer.rows.length === 0 ? (
                  <tr>
                    <Td
                      colSpan={columns}
                      className="text-sm text-muted-foreground"
                    >
                      {t.personalEmptyTrainer}
                    </Td>
                  </tr>
                ) : (
                  trainer.rows.map((row, index) => (
                    <tr key={row.membership_id}>
                      <Td className="tabular-nums text-muted-foreground">
                        {index + 1}
                      </Td>
                      <Td>
                        <Link
                          href={`/members/${row.member_id}`}
                          prefetch={false}
                          className="underline underline-offset-4"
                        >
                          #{row.member_number} {row.first_name} {row.last_name}
                        </Link>
                        {row.upcoming ? (
                          <span className="block text-xs text-muted-foreground">
                            {t.startsOn.replace(
                              "{date}",
                              formatDate(row.start_date),
                            )}
                          </span>
                        ) : null}
                      </Td>
                      <Td className="whitespace-nowrap tabular-nums">
                        {row.paid_on ? formatDate(row.paid_on) : t.notCame}
                      </Td>
                      <Td className="whitespace-nowrap tabular-nums">
                        {formatDate(row.end_date)}
                      </Td>
                      <Td className="whitespace-nowrap tabular-nums">
                        {sessionsLeft(row)}
                      </Td>
                      {showPrices ? (
                        <Td className="text-right tabular-nums">
                          {row.amount ? formatMoney(row.amount) : t.notCame}
                        </Td>
                      ) : null}
                    </tr>
                  ))
                )}
              </tbody>
              {showPrices && trainer.total !== null ? (
                <tfoot>
                  <tr>
                    <Td
                      colSpan={columns - 1}
                      className="text-right font-semibold"
                    >
                      {t.total.replace("{trainer}", trainer.trainerName)}
                    </Td>
                    <Td className="text-right font-semibold tabular-nums">
                      {formatMoney(trainer.total)}
                    </Td>
                  </tr>
                </tfoot>
              ) : null}
            </Table>
          </TableWrapper>
        </section>
      ))}
    </>
  );
}
