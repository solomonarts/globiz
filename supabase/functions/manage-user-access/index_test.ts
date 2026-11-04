import { parseManageUserAccessAction } from "./index.ts";

const id = "6a3e6b7a-3cbe-4c8e-97e0-7fbd541cf024";

Deno.test("accepts an allowlisted student status", () => {
  const result = parseManageUserAccessAction({ targetUserId: id, kind: "student_status", status: "suspended" });
  if (!result || result.kind !== "student_status" || result.status !== "suspended") throw new Error("Expected valid student status action");
});

Deno.test("accepts an allowlisted tutor decision", () => {
  const result = parseManageUserAccessAction({ targetUserId: id, kind: "tutor_decision", decision: "approved" });
  if (!result || result.kind !== "tutor_decision" || result.decision !== "approved") throw new Error("Expected valid tutor decision");
});

Deno.test("rejects malformed and unsupported requests", () => {
  const invalid = [
    null,
    [],
    { targetUserId: "not-a-uuid", kind: "student_status", status: "active" },
    { targetUserId: id, kind: "student_status", status: "admin" },
    { targetUserId: id, kind: "tutor_decision", decision: "published" },
    { targetUserId: id, kind: "assign_role", role: "admin" },
  ];
  if (invalid.some((value) => parseManageUserAccessAction(value) !== null)) throw new Error("Unsupported request passed validation");
});
