"use client";

import { useCallback, useState } from "react";
import { Loader2 } from "lucide-react";
import { FieldError, FormError } from "@/components/common/form-message";
import { useActionToast } from "@/components/common/use-action-toast";
import { useFormAction } from "@/components/common/use-form-action";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { formatDate } from "@/lib/format";
import { me } from "@/lib/i18n/me";
import { changeSessions } from "../actions";
import {
  limitedSessions,
  SESSIONS_LEFT_MAX,
  sessionsLeft,
  sessionsLeftMin,
  sessionsPreview,
  unpaidInPeriod,
  type SessionCount,
  type SessionMembership,
  type SessionType,
  type UnpaidVisit,
} from "../sessions";

export type SessionsMembership = SessionMembership & {
  id: string;
  plan_name: string;
};

/** The form field of each type, as `changeSessions` reads it. */
const FIELD: Record<SessionType, string> = {
  gym: "gymLeft",
  group: "groupLeft",
  personal: "personalLeft",
};

/**
 * S-07 [Izmijeni broj termina] (D-111, BR-055a), owner and admin: the sessions left of
 * each limited type. Only the count changes; the dates, amount and payment stay.
 */
export function SessionsDialog({
  open,
  onOpenChange,
  memberId,
  membership,
  unpaidVisits,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  memberId: string;
  membership: SessionsMembership | null;
  /** The member's unlinked unpaid visits, for the preview of what gets linked. */
  unpaidVisits: UnpaidVisit[];
}) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{me.memberships.sessionsTitle}</DialogTitle>
          {membership ? (
            <DialogDescription>
              {membership.plan_name} · {formatDate(membership.start_date)}–
              {formatDate(membership.end_date)}
              <br />
              {me.memberships.sessionsText}
            </DialogDescription>
          ) : null}
        </DialogHeader>
        {/* Remounted per opening, so a new change never shows the last one's messages. */}
        {open && membership ? (
          <SessionsForm
            memberId={memberId}
            membership={membership}
            unpaidVisits={unpaidVisits}
            onDone={() => onOpenChange(false)}
          />
        ) : null}
      </DialogContent>
    </Dialog>
  );
}

function SessionsForm({
  memberId,
  membership,
  unpaidVisits,
  onDone,
}: {
  memberId: string;
  membership: SessionsMembership;
  unpaidVisits: UnpaidVisit[];
  onDone: () => void;
}) {
  const [state, onSubmit, pending] = useFormAction(changeSessions);
  const close = useCallback(() => onDone(), [onDone]);
  useActionToast(state, close);
  const counts = limitedSessions(membership);
  const [values, setValues] = useState<Record<SessionType, string>>(() => {
    const initial = { gym: "", group: "", personal: "" };
    for (const count of counts)
      initial[count.type] = String(sessionsLeft(count));
    return initial;
  });
  const valid = counts.every((count) => isValid(count, values[count.type]));

  return (
    <form onSubmit={onSubmit} className="grid gap-4" noValidate>
      <input type="hidden" name="memberId" value={memberId} />
      <input type="hidden" name="membershipId" value={membership.id} />
      <FormError>{state.error ?? state.fieldErrors?.form}</FormError>
      {counts.map((count) => (
        <SessionsField
          key={count.type}
          count={count}
          value={values[count.type]}
          onChange={(value) =>
            setValues((current) => ({ ...current, [count.type]: value }))
          }
          unpaid={unpaidInPeriod(membership, unpaidVisits, count.type)}
          error={state.fieldErrors?.[FIELD[count.type]]}
        />
      ))}
      <DialogFooter>
        <DialogClose asChild>
          <Button type="button" variant="outline">
            {me.common.cancel}
          </Button>
        </DialogClose>
        <Button type="submit" disabled={pending || !valid}>
          {pending ? (
            <Loader2 aria-hidden="true" className="animate-spin" />
          ) : null}
          {me.common.save}
        </Button>
      </DialogFooter>
    </form>
  );
}

function isValid(count: SessionCount, value: string): boolean {
  const left = Number(value);
  return (
    value.trim() !== "" &&
    Number.isInteger(left) &&
    left >= sessionsLeftMin(count) &&
    left <= SESSIONS_LEFT_MAX
  );
}

function SessionsField({
  count,
  value,
  onChange,
  unpaid,
  error,
}: {
  count: SessionCount;
  value: string;
  onChange: (value: string) => void;
  unpaid: number;
  error: string | undefined;
}) {
  const id = `sessions-${count.type}`;
  const min = sessionsLeftMin(count);
  const left = Number(value);
  const preview = isValid(count, value)
    ? sessionsPreview(count, left, unpaid)
    : null;

  return (
    <div className="grid gap-2">
      <Label htmlFor={id}>
        {me.memberships.sessionsLeftLabel.replace(
          "{type}",
          me.visitTypes[count.type],
        )}
      </Label>
      <Input
        id={id}
        name={FIELD[count.type]}
        type="number"
        inputMode="numeric"
        min={min}
        max={SESSIONS_LEFT_MAX}
        value={value}
        onChange={(event) => onChange(event.target.value)}
        aria-invalid={Boolean(error) || !preview}
        aria-describedby={`${id}-help ${id}-error`}
      />
      <p id={`${id}-help`} className="text-sm text-muted-foreground">
        {me.memberships.sessionsUsed
          .replace("{used}", String(count.used))
          .replace("{limit}", String(count.limit))}{" "}
        {preview
          ? me.memberships.sessionsTotal.replace(
              "{total}",
              String(preview.total),
            )
          : me.memberships.sessionsLeftInvalid.replace("{min}", String(min))}
        {preview && preview.linked > 0 ? (
          <>
            <br />
            {me.memberships.sessionsLinkPreview
              .replace("{count}", String(preview.linked))
              .replace("{left}", String(preview.leftAfter))}
          </>
        ) : null}
      </p>
      <FieldError id={`${id}-error`}>{error}</FieldError>
    </div>
  );
}
