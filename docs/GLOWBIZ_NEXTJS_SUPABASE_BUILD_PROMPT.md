# GlowBiz: Next.js + Supabase Platform Build Prompt

Copy the prompt below into your coding agent when implementing or completing GlowBiz.

---

## Role and objective

Act as a senior full-stack engineer. Build and maintain **GlowBiz**, a responsive vocational learning, certification, and professional-services marketplace. Use the existing repository as the source of truth: inspect it before changing anything, preserve working flows, and complete missing or incomplete functionality without creating duplicate tables, routes, server actions, RPCs, or Edge Functions.

The stack is **Next.js App Router, React, TypeScript, and Supabase** (PostgreSQL, Auth, RLS, Storage, and Edge Functions where appropriate). Keep service-role credentials server-only. Match the existing design system, routing, libraries, naming, and conventions. Make accessible, mobile-friendly screens with useful loading, empty, success, and error states.

Implement the four product areas below as one integrated platform:

1. Administrator and management dashboard.
2. Student learning dashboard and course player.
3. Tutor teaching dashboard.
4. Public discovery and authenticated services marketplace.

## 1. Identity, roles, and platform security

- Support administrator, student, tutor, and marketplace customer experiences. A customer may also be a student or certified professional; do not create duplicate identities for one person.
- Use Supabase Auth for sign-up, sign-in, recovery, invitations, and sessions. Store profile and role data in the database; users must not be able to grant themselves roles, approve themselves as tutors, or edit protected account fields.
- Enforce authorization in database policies and trusted server code, not only in the UI. Use RLS for every user-facing table and private Storage bucket. Scope all tutor access to courses they own or are explicitly assigned to.
- Keep all sensitive student records under administrator control. Tutors must not receive student names, emails, phone numbers, addresses, or direct identifiers in tutor pages, reports, RPC results, chat labels, logs, or notifications.
- Use pseudonymous, course-scoped learner aliases where tutors need individual progress or assessment workflows. Prevent ordinary users from reading alias-to-identity mappings.
- Validate inputs server-side with the project’s existing validation conventions. Use database RPCs for multi-step operations that require atomic checks and writes. Use `SECURITY DEFINER` functions only when necessary, with a fixed `search_path`, explicit role checks, minimal grants, and authorization based on `auth.uid()`.
- Never put service-role secrets, private file paths, tokens, or private student information in client code or public URLs.

## 2. Curriculum, delivery, and learner progress

- Support programmes, courses, modules, ordered lessons, learning objectives, practical tasks, resources, assessments, competencies, certification levels, and prerequisites. Keep relationships normalized and enforce valid course/module/lesson ownership in the database.
- Lessons can include video, theory, or both, plus practical guidance, safety notes, and downloadable learning resources. Provide a clear, accessible lesson player on mobile and desktop.
- Save student progress as they learn, including current course, module and lesson, video playback position, theory/read position, completion state, and last active time. Resume at the exact saved position and provide a clear “Continue learning” action on the student dashboard.
- Prevent progress from being spoofed. Validate enrollment, course/lesson relationships, checkpoint ranges and completion requirements in trusted server/database code. Calculate progress from required content and assessment rules rather than trusting client-submitted percentages.
- Show students their course/module progress and next required activity. Show tutors course summaries and assigned learners’ progress through pseudonymous aliases, including lesson completion and assessment state. Do not expose personal student identity to tutors.
- Handle content updates and course versions so existing students retain a consistent record of the curriculum and requirements they were assessed against.

## 3. Assessments, reports, and progressive certification

- Support configurable assessment types, attempts, due dates, rubrics, pass marks, tutor grading, feedback, and required practical competency evidence. Enforce attempt limits and eligibility in the database.
- Implement progressive credentials (for example, Level 1 followed by higher levels) from explicit course/module/assessment/competency requirements. Show students what is complete and what remains before they qualify.
- Tutors may review learner performance using aliases and recommend certification only when requirements are met. Their recommendation and supporting assessment record go to administrators. Administrators make the final endorsement, issuance, rejection, or revocation decision.
- Notify students when a certification decision is made. Display issued credentials in the student dashboard with verification details and secure PDF downloads. A certificate must be tied to the correct student, certification level, course/curriculum version and issue state; revoked credentials cannot be presented as valid.
- Generate downloadable assessment/progress reports and certificates. Reports must be authorized for the requesting user, use private/no-store responses or short-lived signed links when stored, and contain only data the requester may see.

## 4. Ratings, reviews, and content moderation

- At completion of each required lesson, collect a required 1–5 star rating and an optional written review tied to that lesson. When a module is completed, collect a required module rating and optional review tied to that module. At course completion, collect a required course rating and optional review.
- A rating/review is submitted from the relevant lesson, module, or course context; derive the subject/content identity from trusted database records rather than trusting client-provided labels.
- Prevent duplicate submissions and enforce rating bounds and completion eligibility. Keep feedback pending until it passes administrator moderation.
- Administrators can filter, approve, reject, or otherwise moderate feedback. Tutors must never see individual review text or identity. Tutors may see only approved, aggregated material ratings, with a minimum group threshold to reduce re-identification risk.
- Never include private feedback text or learner identity in tutor notifications or logs.

## 5. Student-initiated, privacy-protective chat

- A student can initiate a tutor consultation only from within a lesson or module. The subject is automatically set from that lesson/module. Do not offer a generic new-chat form elsewhere.
- Verify the student is enrolled and that the lesson/module belongs to the selected course. Route the consultation only to the assigned/owning tutor.
- Show tutors a pseudonymous learner alias, not the student’s profile identity. Keep conversation records private to the student, assigned tutor, and authorized administrators.
- Block personal contact details and attempts to move conversations off platform in both initial messages and replies. Apply server/database validation to emails, phone numbers, URLs, social handles, and common contact-sharing phrases; provide a clear message explaining the restriction. Do not depend on client-side filtering alone.
- Keep student identities and sensitive learning data out of tutor notifications. Add reporting, read status, and safe conversation closure/moderation where the existing schema supports it.

## 6. Tutor workspace

- Tutors can manage assigned courses and submit course/module/lesson/assessment content for administrator review. Drafts, approval requests, changes requested, publication, and rejection must have clear states and audit history.
- Provide tutor views for assigned course enrolments, pseudonymous individual progress, assessment submissions and results, competency evidence, certification recommendations, and privacy-safe course/module statistics.
- Support filters by course/programme, module, learner alias, assessment state, and period where useful. Clearly label totals, averages, percentages, and estimates; handle missing data explicitly.
- Ensure tutors can only act on assigned content and enrolled learners. A UI link is not an authorization control: check ownership/assignment in every write and protected read.

## 7. Administrator and management dashboard

- Administrators manage users, student records, tutor approval, courses/programmes/modules, content moderation, enrolments, assessments, feedback, certification decisions, marketplace verification, reports, notifications, and audit history.
- Provide searchable/filterable tables and detail views. Use explicit confirmation for high-impact actions such as role changes, account suspension, certificate revocation, and payment status changes.
- Support platform statistics and reports by date range, programme, course, module, tutor, student, status, assessment, and certification where relevant. Include course/module performance, progression, pass rates, completion trends, tutor engagement, feedback trends, certification outcomes, and marketplace bookings/conversion/completion.
- Label counts, rates, averages, and estimates correctly. Exclude or mark incomplete records rather than silently treating missing values as zero. Use indexed queries, secured views/RPCs, and aggregation jobs or materialized views only when required by scale.
- Keep audit logs immutable to ordinary users and record actor, action, target identifier, timestamp, and minimal change metadata. Never log passwords, access tokens, raw message bodies, or unnecessary sensitive information. Log sensitive administrative access.
- Generate CSV and PDF administrative reports with branding, issue date, selected filters, readable headings, and page numbers. Restrict personally identifying reports to authenticated authorized users and use short-lived download links where appropriate.

## 8. Public marketplace and professional services

- Allow visitors to browse service categories and public category summaries without registering. Public pages may show category descriptions, general service information, and aggregate professional counts, but must not reveal private pricing/contact information or unapproved profiles.
- After authentication, customers can view approved certified professional profiles, service details, pricing, availability, and reviews that are approved for public display.
- Professionals can create a service profile only after the required certification is issued. Profile publication and any verification must follow administrator approval rules.
- Support in-app customer/professional messages, booking requests, booking status changes, completion, cancellation, review requests, and payment status where configured. Protect both parties’ personal data and keep communications/bookings auditable.
- Enforce booking availability, pricing snapshots, status transitions, and access rules on the server/database. Do not expose credentials or direct personal contact details in public pages.

## 9. Notifications and operational behavior

- Provide in-app notifications for enrollment decisions, content/course/module availability, lessons and announcements, assessment outcomes and pending work, tutor feedback, certification steps and certificate availability, content moderation decisions, consultations, bookings, professional approval, and review requests.
- Allow users to mark notifications read and configure supported preferences. Deliver only role-appropriate content; tutor notifications must not include student identity or sensitive learning details.
- Make critical workflows resilient to duplicate requests. Use database constraints/idempotency for enrollment, feedback, certification issuance, and booking/payment transitions as appropriate.
- Add helpful indexes for common filters, joins, ownership checks, status queues, time ranges, and report queries. Prefer efficient server-side pagination over loading entire tables.

## 10. Supabase Edge Function architecture for student workflows

Implement student dashboard operations as deployable Supabase Edge Functions and connect Next.js server actions/pages to those endpoints. Keep each function self-contained: put request validation, CORS, authentication, response handling, and operation logic inline in that function directory. Do not rely on a shared `_shared` module for deployable logic.

Use these domain endpoints (extend existing functions rather than duplicating their behavior):

- `student-learning`: authenticated dashboard learning state, enrolled lesson content delivery, short-lived signed lesson resource URLs, session checkpoints, resume state, and lesson completion with its required rating.
- `student-assessments`: authenticated assessment/attempt listing and submission, with server validation and existing database rules enforcing enrollment, due dates, attempt limits and grading state.
- `student-feedback`: required course and module ratings with optional review text, submitted to moderation through existing database workflows.
- `student-certificates`: authenticated certificate listing and PDF generation/download, refusing revoked or expired credentials.
- `student-reports`: generate authenticated student assessment/progress PDFs for the student’s own enrolled course only.
- `student-professional-profile`: create a professional/service profile only from a valid issued certificate and submit it for administrator approval.

Every student function must verify the bearer token with Supabase Auth, check the active student role, and make database calls with the caller JWT and publishable/anon key so RLS and `auth.uid()` remain authoritative. Never use a service-role key for student requests. Use strict method/body limits, origin allowlists for browser calls, `Cache-Control: private, no-store` for personal data, and no sensitive values in error logs. Database constraints/RPCs remain the final authority for transactional eligibility and state transitions. Connect the actual dashboard, player, assessment, feedback, certificate and profile flows to these endpoints; a function that is never called by the app does not complete the workflow.

## 11. Tutor Edge Function architecture

Implement the tutor workspace through self-contained Supabase Edge Functions with inline auth, validation, CORS and response logic. Do not depend on a shared function module. Authenticate the bearer token, require an active approved tutor, use the caller JWT, and confirm course ownership/assignment before returning or changing records.

- `tutor-content`: save tutor lesson and assessment drafts and submit them to administrator content review. Validate course/module ownership and uploaded resource paths; remove uploaded resources if content submission fails.
- `tutor-workspace`: return overview counts, anonymized assessment queues and grades, pseudonymous individual learning progress, course/module analytics with date filters, and programme-filtered performance.
- `tutor-consultations`: expose only alias-labeled consultation inbox/thread data, redact contact/name disclosures from legacy messages, accept replies through the database guard, and support reporting.
- `tutor-certifications`: list eligible learners by pseudonymous alias and submit tutor recommendations to the administrator review workflow. The tutor cannot issue a certificate.

The database remains authoritative for tutor ownership, assessment grading, contact-sharing restrictions, progressive certification eligibility, and audit/notification triggers. Tutor responses must not contain learner profile IDs or personal contact data. Deploy each named function separately.

## 12. Implementation instructions

1. Inspect the existing app, migrations, actions, RPCs, route handlers, Edge Functions, and README before editing. Build on working functionality and identify true gaps; do not replace the stack or duplicate existing flows.
2. Implement the full vertical slice: schema/migration and RLS, trusted server actions/RPCs, UI, validation, error handling, and relevant navigation. Keep each Edge Function self-contained with inline shared logic when a shared function module would make Supabase deployment unreliable.
3. Write additive, timestamped migrations that are safe to apply in order. Avoid destructive schema changes unless explicitly required and provide a safe migration path.
4. Update seed data and environment/setup documentation when the feature requires it. Never add real credentials or private user data.
5. Use clear TypeScript types and accessible UI semantics. Keep components small enough to maintain and preserve established visual styling.
6. Run the repository’s available lint, type-check, build, and relevant tests when the task explicitly requests verification or the project workflow requires them. Report what ran and any tooling limitation accurately.
7. In the final response, summarize what was implemented, identify important migrations/setup steps, state verification performed, and list any remaining blockers. Do not claim a workflow is complete unless its database authorization and UI path are both implemented.

## Completion criteria

The platform is ready for review when each role can complete its authorized end-to-end workflows; students can resume learning and access their own reports/certificates; tutors can manage content and assigned learner progress without identity access; administrators can moderate and audit sensitive actions; reviews remain anonymous to tutors; chats begin only from lesson/module context with protected identities; and public visitors can discover categories while bookings and professional details remain protected behind the correct account and approval checks.
