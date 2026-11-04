import { parseInviteInput } from "./index.ts";

Deno.test("normalizes valid invitation details", () => {
  const result = parseInviteInput({ email: "  Tutor@Example.com ", fullName: "  Amina Tutor  ", role: "tutor", qualifications: "Beauty educator" });
  if (!result || result.email !== "tutor@example.com" || result.fullName !== "Amina Tutor" || result.role !== "tutor") {
    throw new Error("Valid tutor invitation was not normalized");
  }
});

Deno.test("rejects admin invitations and invalid fields", () => {
  const invalid = [
    { email: "not-an-email", fullName: "Valid Name", role: "student" },
    { email: "admin@example.com", fullName: "Admin User", role: "admin" },
    { email: "person@example.com", fullName: "A", role: "customer" },
    { email: "person@example.com", fullName: "Valid Name", role: "student", qualifications: "x".repeat(2001) },
    null,
  ];
  if (invalid.some((body) => parseInviteInput(body) !== null)) throw new Error("Invalid invitation passed validation");
});
