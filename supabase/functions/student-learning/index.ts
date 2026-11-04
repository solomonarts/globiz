import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const origins = (Deno.env.get("APP_ALLOWED_ORIGINS") ?? "").split(",").map((item) => item.trim()).filter(Boolean);
function response(request: Request, body: unknown, status = 200) {
  const headers = new Headers({ "Content-Type": "application/json; charset=utf-8", "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff", "Vary": "Origin" });
  const origin = request.headers.get("origin");
  if (origin && origins.includes(origin)) { headers.set("Access-Control-Allow-Origin", origin); headers.set("Access-Control-Allow-Headers", "authorization, apikey, content-type, x-client-info"); headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS"); headers.set("Access-Control-Max-Age", "600"); }
  return new Response(JSON.stringify(body), { status, headers });
}
function safeOrigin(request: Request) { const origin = request.headers.get("origin"); return !origin || origins.includes(origin); }
async function bodyJson(request: Request) { const text = await request.text(); if (text.length > 16000) throw new Error("request_too_large"); return JSON.parse(text) as Record<string, unknown>; }
Deno.serve(async (request) => {
  if (!safeOrigin(request)) return response(request, { error: "origin_not_allowed" }, 403);
  if (request.method === "OPTIONS") return new Response("", { status: 204, headers: { "Access-Control-Allow-Origin": request.headers.get("origin") ?? "", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "GET, POST, OPTIONS", "Access-Control-Max-Age": "600", "Vary": "Origin" } });
  if (request.method !== "GET" && request.method !== "POST") return response(request, { error: "method_not_allowed" }, 405);
  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return response(request, { error: "unauthorized" }, 401);
  const url = Deno.env.get("SUPABASE_URL"); const key = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  if (!url || !key) return response(request, { error: "service_unavailable" }, 503);
  const db = createClient(url, key, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false, autoRefreshToken: false } });
  const { data: auth, error: authError } = await db.auth.getUser();
  if (authError || !auth.user) return response(request, { error: "unauthorized" }, 401);
  const { data: profile } = await db.from("profiles").select("role,account_status").eq("id", auth.user.id).maybeSingle();
  if (profile?.role !== "student" || profile.account_status !== "active") return response(request, { error: "active_student_required" }, 403);
  try {
    if (request.method === "GET") {
      const operation = new URL(request.url).searchParams.get("operation");
      if (operation === "dashboard") {
        const [enrolments, sessions, progress, certificates, applications] = await Promise.all([
          db.from("enrolments").select("id,course_id,status,progress,created_at,courses(id,title,category,level,programme_id,minimum_completion,programmes(title),modules(id,title,position,lessons(id,title,position,required,duration_minutes)))").eq("student_id", auth.user.id).in("status", ["active", "completed"]).order("created_at", { ascending: false }).limit(30),
          db.from("learning_sessions").select("course_id,lesson_id,last_active_at,total_seconds_estimate").eq("student_id", auth.user.id).order("last_active_at", { ascending: false }),
          db.from("lesson_progress").select("lesson_id,completed_at,updated_at,lessons(title,modules(title,course_id))").eq("student_id", auth.user.id).order("updated_at", { ascending: false }).limit(5000),
          db.from("certificates").select("id,certificate_number,issued_at,revoked_at,certifications(title),courses(title)").eq("student_id", auth.user.id).order("issued_at", { ascending: false }).limit(8),
          db.from("certification_applications").select("id,status,created_at,certifications(title),courses(title)").eq("student_id", auth.user.id).order("created_at", { ascending: false }).limit(6),
        ]);
        const failed = [enrolments, sessions, progress, certificates, applications].find((item) => item.error);
        if (failed?.error) return response(request, { error: "dashboard_unavailable" }, 500);
        return response(request, { enrolments: enrolments.data ?? [], sessions: sessions.data ?? [], lesson_progress: progress.data ?? [], certificates: certificates.data ?? [], certification_applications: applications.data ?? [] });
      }
      if (operation === "lesson") {
        const courseId = new URL(request.url).searchParams.get("course_id") ?? ""; const lessonId = new URL(request.url).searchParams.get("lesson_id") ?? "";
        if (!uuid.test(courseId) || !uuid.test(lessonId)) return response(request, { error: "invalid_lesson_reference" }, 400);
        const { data: enrolment } = await db.from("enrolments").select("status").eq("student_id", auth.user.id).eq("course_id", courseId).in("status", ["active", "completed"]).maybeSingle();
        if (!enrolment) return response(request, { error: "enrolment_required" }, 403);
        const { data: lesson, error } = await db.from("lessons").select("id,title,description,theory,video_url,resource_path,duration_minutes,position,required,lesson_type,objectives,practical_instructions,safety_guidance,module_id").eq("id", lessonId).maybeSingle();
        if (error || !lesson) return response(request, { error: "lesson_not_found" }, 404);
        const { data: module } = await db.from("modules").select("id,title,course_id").eq("id", lesson.module_id).eq("course_id", courseId).maybeSingle();
        if (!module) return response(request, { error: "lesson_not_in_course" }, 404);
        const [{ data: course }, { data: session }, { data: progress }] = await Promise.all([
          db.from("courses").select("id,title").eq("id", courseId).maybeSingle(),
          db.from("learning_sessions").select("video_position_seconds,theory_position_percent,last_active_at").eq("student_id", auth.user.id).eq("course_id", courseId).eq("lesson_id", lessonId).maybeSingle(),
          db.from("lesson_progress").select("completed_at,watched_seconds,updated_at").eq("student_id", auth.user.id).eq("lesson_id", lessonId).maybeSingle(),
        ]);
        let resourceUrl: string | null = null;
        if (lesson.resource_path) { const signed = await db.storage.from("lesson-resources").createSignedUrl(lesson.resource_path, 600); resourceUrl = signed.data?.signedUrl ?? null; }
        return response(request, { course, module, lesson: { ...lesson, resource_path: undefined, resource_url: resourceUrl }, session, progress });
      }
      return response(request, { error: "unknown_operation" }, 400);
    }
    const payload = await bodyJson(request); const operation = payload.operation;
    if (operation === "lesson") {
      const courseId = payload.course_id; const lessonId = payload.lesson_id;
      if (typeof courseId !== "string" || !uuid.test(courseId) || typeof lessonId !== "string" || !uuid.test(lessonId)) return response(request, { error: "invalid_lesson_reference" }, 400);
      const [{ data: enrolment }, { data: course }, { data: progress }, { data: session }, { data: moduleReviews }, { data: selectedLesson }] = await Promise.all([
        db.from("enrolments").select("status").eq("student_id", auth.user.id).eq("course_id", courseId).in("status", ["active", "completed"]).maybeSingle(),
        db.from("courses").select("id,title,modules(id,title,position,lessons(id,title,description,theory,video_url,duration_minutes,position,required,lesson_type,objectives,instructor_notes,practical_instructions,safety_guidance))").eq("id", courseId).maybeSingle(),
        db.from("lesson_progress").select("completed_at,watched_seconds").eq("student_id", auth.user.id).eq("lesson_id", lessonId).maybeSingle(),
        db.from("learning_sessions").select("video_position_seconds,theory_position_percent").eq("student_id", auth.user.id).eq("course_id", courseId).eq("lesson_id", lessonId).maybeSingle(),
        db.from("feedback").select("module_id").eq("student_id", auth.user.id).eq("course_id", courseId).not("module_id", "is", null).is("lesson_id", null),
        db.from("lessons").select("id,module_id,resource_path").eq("id", lessonId).maybeSingle(),
      ]);
      if (!enrolment || !course) return response(request, { error: "enrolment_or_course_not_found" }, 404);
      const modules = (course.modules ?? []) as Array<{ id: string; lessons: Array<{ id: string }> }>;
      if (!modules.some((module) => module.lessons.some((lesson) => lesson.id === lessonId)) || selectedLesson?.module_id == null) return response(request, { error: "lesson_not_in_course" }, 404);
      let resourceUrl: string | null = null;
      if (selectedLesson.resource_path) { const { data } = await db.storage.from("lesson-resources").createSignedUrl(selectedLesson.resource_path, 600); resourceUrl = data?.signedUrl ?? null; }
      return response(request, { course, enrolment_status: enrolment.status, progress, session, module_reviews: moduleReviews ?? [], lesson_id: lessonId, resource_url: resourceUrl });
    }
    if (operation === "dashboard") {
      const [enrolments, sessions, progress, certificates, applications] = await Promise.all([
        db.from("enrolments").select("id,course_id,status,progress,created_at,courses(id,title,category,level,programme_id,minimum_completion,programmes(title),modules(id,title,position,lessons(id,title,position,required,duration_minutes)))").eq("student_id", auth.user.id).in("status", ["active", "completed"]).order("created_at", { ascending: false }).limit(30),
        db.from("learning_sessions").select("course_id,lesson_id,last_active_at,total_seconds_estimate").eq("student_id", auth.user.id).order("last_active_at", { ascending: false }),
        db.from("lesson_progress").select("lesson_id,completed_at,updated_at,lessons(title,modules(title,course_id))").eq("student_id", auth.user.id).order("updated_at", { ascending: false }).limit(5000),
        db.from("certificates").select("id,certificate_number,issued_at,revoked_at,certifications(title),courses(title)").eq("student_id", auth.user.id).order("issued_at", { ascending: false }).limit(8),
        db.from("certification_applications").select("id,status,created_at,certifications(title),courses(title)").eq("student_id", auth.user.id).order("created_at", { ascending: false }).limit(6),
      ]);
      const failed = [enrolments, sessions, progress, certificates, applications].find((item) => item.error);
      if (failed?.error) return response(request, { error: "dashboard_unavailable" }, 500);
      return response(request, { enrolments: enrolments.data ?? [], sessions: sessions.data ?? [], lesson_progress: progress.data ?? [], certificates: certificates.data ?? [], certification_applications: applications.data ?? [] });
    }
    if (operation === "save_position") {
      const courseId = payload.course_id; const lessonId = payload.lesson_id; const videoSeconds = payload.video_seconds; const theoryPercent = payload.theory_percent;
      if (typeof courseId !== "string" || !uuid.test(courseId) || typeof lessonId !== "string" || !uuid.test(lessonId) || !Number.isInteger(videoSeconds) || (videoSeconds as number) < 0 || (videoSeconds as number) > 86400 || typeof theoryPercent !== "number" || !Number.isFinite(theoryPercent) || theoryPercent < 0 || theoryPercent > 100) return response(request, { error: "invalid_learning_checkpoint" }, 400);
      const { data, error } = await db.rpc("save_student_learning_position", { p_course_id: courseId, p_lesson_id: lessonId, p_video_seconds: videoSeconds, p_theory_percent: theoryPercent });
      if (error) return response(request, { error: "checkpoint_rejected", message: error.message }, 422);
      return response(request, { ok: data === true });
    }
    if (operation === "complete_lesson") {
      const courseId = payload.course_id; const lessonId = payload.lesson_id; const rating = payload.rating; const review = payload.review ?? "";
      if (typeof courseId !== "string" || !uuid.test(courseId) || typeof lessonId !== "string" || !uuid.test(lessonId) || !Number.isInteger(rating) || (rating as number) < 1 || (rating as number) > 5 || typeof review !== "string" || review.length > 2000) return response(request, { error: "invalid_lesson_completion" }, 400);
      const { data, error } = await db.rpc("student_complete_lesson", { p_course_id: courseId, p_lesson_id: lessonId, p_rating: rating, p_review: review });
      if (error) return response(request, { error: "completion_rejected", message: error.message }, 422);
      return response(request, { ok: true, result: data });
    }
    return response(request, { error: "unknown_operation" }, 400);
  } catch (error) {
    const message = error instanceof Error && error.message === "request_too_large" ? "request_too_large" : "invalid_request";
    return response(request, { error: message }, message === "request_too_large" ? 413 : 400);
  }
});
