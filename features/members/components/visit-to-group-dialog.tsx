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
import { Label } from "@/components/ui/label";
import { Select } from "@/components/ui/select";
import type { SaleCatalog } from "@/features/memberships/catalog";
import { classTimesOf } from "@/features/memberships/class-time";
import {
  formatClockTime,
  formatDate,
  formatTime,
  gymDateOf,
} from "@/lib/format";
import { me } from "@/lib/i18n/me";
import { visitToGroup } from "../actions";

export type GroupCorrection = {
  visit: { id: string; checked_in_at: string };
  /** The Grupni that covers the visit's day, as the database will pick it (BR-074). */
  membership: { plan_name: string; trainer_id: string | null };
};

/** ISO weekday (1 = Monday) of a gym date, as class_slots stores it. */
function isoWeekday(date: string): number {
  return new Date(`${date}T12:00:00Z`).getUTCDay() || 7;
}

/**
 * D-110: S-07 [Ipak grupni trening]. The unpaid gym visit becomes a group visit with the
 * trainer and class chosen here and uses a session of the Grupni; "Bez časa iz rasporeda"
 * when the trainer held the class at another time that day.
 */
export function VisitToGroupDialog({
  open,
  onOpenChange,
  memberId,
  correction,
  catalog,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  memberId: string;
  correction: GroupCorrection | null;
  catalog: SaleCatalog;
}) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>{me.members.toGroup}</DialogTitle>
          {correction ? (
            <DialogDescription>
              {me.members.toGroupText
                .replace("{date}", formatDate(correction.visit.checked_in_at))
                .replace("{time}", formatTime(correction.visit.checked_in_at))
                .replace("{plan}", correction.membership.plan_name)}
            </DialogDescription>
          ) : null}
        </DialogHeader>
        {/* Remounted per opening, so each correction starts from the membership's trainer. */}
        {open && correction ? (
          <VisitToGroupForm
            memberId={memberId}
            correction={correction}
            catalog={catalog}
            onDone={() => onOpenChange(false)}
          />
        ) : null}
      </DialogContent>
    </Dialog>
  );
}

function VisitToGroupForm({
  memberId,
  correction,
  catalog,
  onDone,
}: {
  memberId: string;
  correction: GroupCorrection;
  catalog: SaleCatalog;
  onDone: () => void;
}) {
  const [state, onSubmit, pending] = useFormAction(visitToGroup);
  const close = useCallback(() => onDone(), [onDone]);
  useActionToast(state, close);
  // BR-075: the group trainers; the membership's trainer first.
  const trainers = catalog.trainers.filter((trainer) => trainer.group);
  const [trainerId, setTrainerId] = useState(
    trainers.some((trainer) => trainer.id === correction.membership.trainer_id)
      ? (correction.membership.trainer_id ?? "")
      : "",
  );
  const [classTime, setClassTime] = useState("");
  const weekday = isoWeekday(gymDateOf(correction.visit.checked_in_at));
  const classes = classTimesOf(catalog.classTimes, trainerId).filter((time) =>
    time.weekdays.includes(weekday),
  );

  return (
    <form onSubmit={onSubmit} className="grid gap-4" noValidate>
      <input type="hidden" name="memberId" value={memberId} />
      <input type="hidden" name="visitId" value={correction.visit.id} />
      <FormError>{state.error}</FormError>
      <div className="grid gap-2">
        <Label htmlFor="to-group-trainer">{me.reception.trainer}</Label>
        <Select
          id="to-group-trainer"
          name="trainerId"
          value={trainerId}
          required
          onChange={(event) => {
            setTrainerId(event.target.value);
            setClassTime("");
          }}
          aria-invalid={Boolean(state.fieldErrors?.trainerId)}
          aria-describedby="to-group-trainer-error"
        >
          <option value="" disabled>
            {me.memberships.trainerPlaceholder}
          </option>
          {trainers.map((trainer) => (
            <option key={trainer.id} value={trainer.id}>
              {trainer.full_name}
            </option>
          ))}
        </Select>
        <FieldError id="to-group-trainer-error">
          {state.fieldErrors?.trainerId}
        </FieldError>
      </div>
      <div className="grid gap-2">
        <Label htmlFor="to-group-class">{me.reception.slot}</Label>
        <Select
          id="to-group-class"
          name="classTime"
          value={classTime}
          onChange={(event) => setClassTime(event.target.value)}
        >
          <option value="">{me.reception.noSlot}</option>
          {classes.map((time) => (
            <option key={time.starts_at} value={time.starts_at}>
              {me.reception.slotAt.replace(
                "{time}",
                formatClockTime(time.starts_at),
              )}
            </option>
          ))}
        </Select>
      </div>
      <DialogFooter>
        <DialogClose asChild>
          <Button type="button" variant="outline">
            {me.common.cancel}
          </Button>
        </DialogClose>
        <Button type="submit" disabled={pending || !trainerId}>
          {pending ? (
            <Loader2 aria-hidden="true" className="animate-spin" />
          ) : null}
          {me.common.save}
        </Button>
      </DialogFooter>
    </form>
  );
}
