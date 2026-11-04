# GlowBiz

Responsive vocational learning and marketplace application built with Next.js App Router, TypeScript, Tailwind CSS, and Supabase.

## Start locally

1. Install Node.js 20.9 or newer and dependencies with `npm install`.
2. Create a Supabase project and copy `.env.example` to `.env.local`.
3. Set `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, and `NEXT_PUBLIC_SITE_URL` for your deployment. Keep the service role key server-only; never expose it to browser code.
4. Apply all migrations in `supabase/migrations` in timestamp order using the Supabase SQL editor or Supabase CLI.
5. Set `SUPABASE_SERVICE_ROLE_KEY` in `.env.local` for privileged Next.js recovery/admin operations. Keep this server-only key out of browser code and public environment variables. Invitation and account-access functions use the key only inside the Supabase Edge runtime.
6. Set `REPORT_SIGNING_SECRET` to a randomly generated secret of at least 32 characters. It signs administrator report links, which expire after ten minutes. Keep it server-only.
7. Create a tutor account, promote it to approved as described below, then run `supabase/seed.sql` to add a starter curriculum.
8. In Supabase Auth, set the local site URL and allowed redirect URL to `http://localhost:3000`.
9. Run `npm run dev`.

### Deploy Supabase Edge Functions

Apply all migrations in timestamp order, including `202610290001_edge_function_security.sql`, `202610290002_course_version_workflow.sql`, `202610290004_tutor_edge_functions.sql`, and `202610290005_admin_workflows.sql`, and `202610290006_marketplace_customer_privacy.sql`, before deploying the functions. Each Edge Function is self-contained in its own directory with its request validation and CORS handling inline. Set the browser origins allowed to invoke them, then deploy with the Supabase CLI:

```sh
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
supabase secrets set APP_ALLOWED_ORIGINS="http://localhost:3000,https://your-domain.example" APP_SITE_URL="https://your-domain.example"
supabase functions deploy manage-user-access
supabase functions deploy invite-platform-user
supabase functions deploy student-learning
supabase functions deploy student-assessments
supabase functions deploy student-feedback
supabase functions deploy student-certificates
supabase functions deploy student-reports
supabase functions deploy student-professional-profile
supabase functions deploy tutor-content
supabase functions deploy tutor-workspace
supabase functions deploy tutor-consultations
supabase functions deploy tutor-certifications
supabase functions deploy admin-governance
supabase functions deploy admin-reporting
supabase functions deploy admin-users
supabase functions deploy admin-support
supabase functions deploy marketplace-public
supabase functions deploy marketplace-transactions
```

Supabase provides `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` to deployed Edge Functions. Do not put the service-role key in `.env.local` or a client bundle for this function. The function requires a caller's valid Supabase access token and an active administrator profile. It accepts only `student_status` actions for student accounts and `tutor_decision` actions for tutor accounts; the caller cannot select the actor, target role, or arbitrary profile fields. Requests are limited to 30 changes per administrator per hour using the database-backed limiter.

```http
POST /functions/v1/manage-user-access
Authorization: Bearer <administrator-access-token>
apikey: <Supabase-publishable-key>
Content-Type: application/json

{"targetUserId":"<profile-uuid>","kind":"student_status","status":"suspended"}
```

The function returns `{ "ok": true, "data": { "userId": "…", "status": "…" } }` on success and a stable `{ "ok": false, "error": { "code": "…", "message": "…" } }` envelope on failure. Tutor decisions accept `approved`, `changes_requested`, `rejected`, `suspended`, or `deactivated`. Profile writes use the caller's JWT so existing RLS, audit and notification triggers see the administrator actor; the service-role client is restricted to Supabase Auth ban/unban and rate-limit operations. The student and tutor status forms call this function through their authenticated Next.js server actions.

Run Edge Function validation tests with `deno test supabase/functions/manage-user-access/index_test.ts` and `deno test supabase/functions/invite-platform-user/index_test.ts` in an environment with Deno installed. These tests cover request validation; authorization, database RLS and Auth rollback behavior still require an integration test project.

The first account is a student, tutor, or customer. To bootstrap the first administrator, create and verify an account, then run this once in the Supabase SQL editor using that account's email:

```sql
update public.profiles p
set role = 'admin', account_status = 'active', tutor_approved = true, tutor_application_status = 'approved'
from auth.users u
where p.id = u.id and u.email = 'admin@example.com';
```

New student accounts are pending until an administrator approves them in **Admin → People**. Tutor accounts are not allowed to publish or manage courses until an administrator approves them by setting `tutor_approved = true` in the profile. Course content submitted by a tutor should use `pending` status for review before publication. The included seed creates a starter beauty programme and sample lessons after an approved tutor exists.

## Included foundation

- Public GlowBiz landing page and service discovery, professional profiles, signup, and login.
- Public marketplace category counts, service search, verified credential links, published portfolio data, private customer favourites and reviews, participant-only messaging, and administrator profile/service moderation.
- Customer and professional booking workspaces with availability checks, Kampala-time scheduling, status history, cancellation and reschedule responses, confirmed slot conflict protection, and payment-ready booking and reconciliation records.
- Authenticated student, tutor, customer, and administrator workspaces with database-backed metrics and row-level access enforced by Supabase.
- Administrator student directory with secure email invitations, approval and suspension, enrolment review, course and cohort assignment, private notes, competency history, account recovery, audited changes, and authorized JSON progress exports.
- Administrative reporting center with filterable PDF and CSV exports, short-lived administrator-bound links, and personal student progress reports.
- Role-scoped in-app notifications for learning, assessment, certification, moderation, consultation, messaging, profile, and booking events, with per-category preferences and read state.
- Administrator performance analytics for custom-period daily, weekly, and monthly activity, plus course, programme, module, cohort, tutor, assessment, certification, feedback, and marketplace comparisons.
- Student dashboard with course progress, assessment results, saved learning positions, lesson and module feedback, personal progress PDFs, and verified certificate downloads.
- Tutor course content editor for structured video, theory, practical, safety, and resource-backed lessons submitted for moderation.
- Tutor directory and approval, with minimum group thresholds for anonymized learning and feedback summaries.
- Additive normalized schema for roles, tutor assignments, course categories and versions, assessment questions and answer keys, certification rules, professional availability, payments, notifications, audit events, compatibility views, and private storage buckets. Apply migrations in timestamp order; normalized aliases preserve the existing application tables as the write model during rollout.
- RLS policies, immutable administrator-only audit history with changed-field metadata, sensitive record access logging, profile role protection, helpful indexes, and private storage policies for learning materials, submissions, and certificates.

The Supabase migration is the source of truth for database structure. KPI results are queried from Supabase; empty states are shown when there are no records.

## Edge Function coverage

Implemented Edge Functions include `manage-user-access`, `invite-platform-user`, `student-learning`, `student-assessments`, `student-feedback`, `student-certificates`, `student-reports`, and `student-professional-profile`, plus `tutor-content`, `tutor-workspace`, `tutor-consultations`, `tutor-certifications`, `admin-governance`, `admin-reporting`, `admin-users`, and `admin-support`. Student dashboard reads, lesson content delivery and signed resources, progress checkpoints/completion, assessment listing/submission, course/module reviews, assessment PDF reports, certificate listing/PDF generation, and certified professional profile submission use authenticated student Edge endpoints. Tutor content drafts/submissions, assessment queues and grading, period/program/course analytics, pseudonymous learner progress, moderated consultation inbox/replies, and certification recommendations use authenticated tutor Edge endpoints. Tutor analytics use `tutor_course_analytics` from migration `202610290004_tutor_edge_functions.sql`; consultation messages reject common contact details and explicit personal name disclosures. Student workflow functions use the caller JWT and RLS-scoped Supabase client; they do not use the service-role key. The certificate download route proxies to the Edge PDF generator when deployed and retains its authenticated local renderer as a fallback. Account-management functions authenticate administrators, validate request bodies, apply database-backed rate limits, and keep the service-role key inside the Edge runtime. Administrator content, enrolment, certification, professional, feedback and booking decisions use `admin-governance`; dashboard analytics and sensitive report generation use `admin-reporting`; account status and tutor permission changes use `manage-user-access`; account reset/deletion requests use `admin-users`; user initiated support conversations and replies use `admin-support`.

Curriculum version creation is implemented as the transactional `admin_create_course_version` Postgres function and exposed in the admin course governance page. It snapshots course modules, lessons and assessment content, records the reason and actor, and restricts snapshot reads to administrators and assigned tutors so answer keys are not exposed to students. Other workflows use authenticated Next.js routes/actions and database-side RLS/RPCs where appropriate. Marketplace discovery and transactions are exposed through dedicated Edge Functions while retaining existing database functions as the transaction and authorization layer.

Payment processing and outbound email remain inactive: there is no payment provider, webhook signing secret or email delivery provider configured. Do not accept client payment confirmations or enable email preferences until those integrations and their verification workflows are added. Admin invitations are restricted to student, tutor and customer roles; elevated admin invitations remain a manual bootstrap operation. Account deletion and profile-reset requests can be initiated by an authenticated user and reviewed by administrators in Admin → Account requests. Direct administrator deletion requires email confirmation and protects administrator accounts; reset preserves authentication, role and learning records. Resource validation currently occurs in authenticated upload actions plus storage policies rather than a duplicate Edge endpoint.

Apply `202610290005_admin_workflows.sql` and `202610290006_marketplace_customer_privacy.sql` in timestamp order before deploying the admin and marketplace functions. Set `SUPABASE_SERVICE_ROLE_KEY` only in Supabase Edge secrets for `admin-users` and `admin-support`; set `APP_ALLOWED_ORIGINS` to the exact app origins. These two functions use service role only after independently validating the caller JWT and active profile. Admin support message bodies are never copied into audit metadata.

Marketplace Edge Functions are self-contained: `marketplace-public` returns category counts and limited professional summaries to anonymous visitors, while requiring an active customer account for professional details, services, pricing, reviews and portfolio metadata. `marketplace-transactions` handles booking requests and status responses, customer initiated professional chats, participant messaging, inbox/thread access, read state, favourites, service reviews and conversation reports. Both use the caller JWT with the anon/publishable key; authorization and booking rules remain enforced by RLS and the existing security-definer marketplace RPCs.
# globiz
