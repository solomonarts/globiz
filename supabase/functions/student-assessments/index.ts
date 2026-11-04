import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const origins = (Deno.env.get("APP_ALLOWED_ORIGINS") ?? "").split(",").map((value) => value.trim()).filter(Boolean);
function respond(request: Request, body: unknown, status = 200) { const headers = new Headers({ "Content-Type": "application/json; charset=utf-8", "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff", "Vary": "Origin" }); const origin = request.headers.get("origin"); if (origin && origins.includes(origin)) { headers.set("Access-Control-Allow-Origin", origin); headers.set("Access-Control-Allow-Headers", "authorization, apikey, content-type, x-client-info"); headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS"); headers.set("Access-Control-Max-Age", "600"); } return new Response(JSON.stringify(body), { status, headers }); }
Deno.serve(async (request) => {
  const origin = request.headers.get("origin"); if (origin && !origins.includes(origin)) return respond(request, { error: "origin_not_allowed" }, 403);
  if (request.method === "OPTIONS") return new Response("", { status: 204, headers: { "Access-Control-Allow-Origin": origin ?? "", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "GET, POST, OPTIONS", "Access-Control-Max-Age": "600", "Vary": "Origin" } });
  if (!new Set(["GET", "POST"]).has(request.method)) return respond(request, { error: "method_not_allowed" }, 405);
  const authorization = request.headers.get("authorization") ?? ""; if (!authorization.startsWith("Bearer ")) return respond(request, { error: "unauthorized" }, 401);
  const url = Deno.env.get("SUPABASE_URL"); const key = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY"); if (!url || !key) return respond(request, { error: "service_unavailable" }, 503);
  const db = createClient(url, key, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false, autoRefreshToken: false } });
  const { data: auth, error: authError } = await db.auth.getUser(); if (authError || !auth.user) return respond(request, { error: "unauthorized" }, 401);
  const { data: profile } = await db.from("profiles").select("role,account_status").eq("id", auth.user.id).maybeSingle(); if (profile?.role !== "student" || profile.account_status !== "active") return respond(request, { error: "active_student_required" }, 403);
  if (request.method === "GET") {
    const [{ data: enrolments, error: enrollmentError }, { data: attempts, error: attemptsError }] = await Promise.all([
      db.from("enrolments").select("course_id").eq("student_id", auth.user.id).in("status", ["active", "completed"]),
      db.from("assessment_submissions").select("id,assessment_id,answer,file_path,score,feedback,submitted_at,reviewed_at,assessments(title,pass_score,max_score)").eq("student_id", auth.user.id).order("submitted_at", { ascending: false }),
    ]);
    if (enrollmentError || attemptsError) return respond(request, { error: "assessment_data_unavailable" }, 500);
    const courseIds = (enrolments ?? []).map((item) => item.course_id);
    const { data: assessments, error } = courseIds.length ? await db.from("assessments").select("id,title,instructions,assessment_type,pass_score,max_score,max_attempts,due_at,criteria,courses(title),modules(title)").in("course_id", courseIds).eq("status", "published").order("due_at") : { data: [], error: null };
    if (error) return respond(request, { error: "assessment_data_unavailable" }, 500);
    return respond(request, { assessments: assessments ?? [], attempts: attempts ?? [] });
  }
  try {
    const text = await request.text(); if (text.length > 30000) return respond(request, { error: "request_too_large" }, 413);
    const payload = JSON.parse(text) as Record<string, unknown>; const assessmentId = payload.assessment_id; const answer = payload.answer ?? ""; const filePath = payload.file_path ?? null;
    if (typeof assessmentId !== "string" || !uuid.test(assessmentId) || typeof answer !== "string" || answer.length > 20000 || (filePath !== null && (typeof filePath !== "string" || !filePath.startsWith(`${auth.user.id}/${assessmentId}/`) || filePath.includes("..")))) return respond(request, { error: "invalid_submission" }, 400);
    if (!answer.trim() && !filePath) return respond(request, { error: "answer_or_upload_required" }, 400);
    if (filePath) { const { error: fileError } = await db.storage.from("student-submissions").createSignedUrl(filePath, 30); if (fileError) return respond(request, { error: "submission_file_not_found" }, 400); }
    const { data, error } = await db.from("assessment_submissions").insert({ assessment_id: assessmentId, student_id: auth.user.id, answer, file_path: filePath }).select("id,assessment_id,submitted_at").single();
    if (error) return respond(request, { error: "submission_rejected", message: error.message }, 422);
    return respond(request, { ok: true, submission: data });
  } catch { return respond(request, { error: "invalid_request" }, 400); }
});
