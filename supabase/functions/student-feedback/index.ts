import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const allowedOrigins = (Deno.env.get("APP_ALLOWED_ORIGINS") ?? "").split(",").map((value) => value.trim()).filter(Boolean);
function respond(request: Request, body: unknown, status = 200) { const headers = new Headers({ "Content-Type": "application/json; charset=utf-8", "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff", "Vary": "Origin" }); const origin = request.headers.get("origin"); if (origin && allowedOrigins.includes(origin)) { headers.set("Access-Control-Allow-Origin", origin); headers.set("Access-Control-Allow-Headers", "authorization, apikey, content-type, x-client-info"); headers.set("Access-Control-Allow-Methods", "POST, OPTIONS"); headers.set("Access-Control-Max-Age", "600"); } return new Response(JSON.stringify(body), { status, headers }); }
Deno.serve(async (request) => {
  const origin = request.headers.get("origin"); if (origin && !allowedOrigins.includes(origin)) return respond(request, { error: "origin_not_allowed" }, 403);
  if (request.method === "OPTIONS") return new Response("", { status: 204, headers: { "Access-Control-Allow-Origin": origin ?? "", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Max-Age": "600", "Vary": "Origin" } });
  if (request.method !== "POST") return respond(request, { error: "method_not_allowed" }, 405);
  const authorization = request.headers.get("authorization") ?? ""; if (!authorization.startsWith("Bearer ")) return respond(request, { error: "unauthorized" }, 401);
  const url = Deno.env.get("SUPABASE_URL"); const key = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY"); if (!url || !key) return respond(request, { error: "service_unavailable" }, 503);
  const db = createClient(url, key, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false, autoRefreshToken: false } });
  const { data: auth, error: authError } = await db.auth.getUser(); if (authError || !auth.user) return respond(request, { error: "unauthorized" }, 401);
  const { data: profile } = await db.from("profiles").select("role,account_status").eq("id", auth.user.id).maybeSingle(); if (profile?.role !== "student" || profile.account_status !== "active") return respond(request, { error: "active_student_required" }, 403);
  try {
    const text = await request.text(); if (text.length > 12000) return respond(request, { error: "request_too_large" }, 413);
    const payload = JSON.parse(text) as Record<string, unknown>; const rating = payload.rating; const review = payload.review ?? "";
    if (!Number.isInteger(rating) || (rating as number) < 1 || (rating as number) > 5 || typeof review !== "string" || review.length > 2000) return respond(request, { error: "invalid_feedback" }, 400);
    let rpc: string; let args: Record<string, unknown>;
    if (payload.operation === "course") { if (typeof payload.course_id !== "string" || !uuid.test(payload.course_id)) return respond(request, { error: "invalid_course" }, 400); rpc = "student_submit_course_feedback"; args = { p_course_id: payload.course_id, p_rating: rating, p_review: review }; }
    else if (payload.operation === "module") { if (typeof payload.module_id !== "string" || !uuid.test(payload.module_id)) return respond(request, { error: "invalid_module" }, 400); rpc = "student_submit_module_feedback"; args = { p_module_id: payload.module_id, p_rating: rating, p_review: review }; }
    else return respond(request, { error: "unknown_operation" }, 400);
    const { data, error } = await db.rpc(rpc, args); if (error) return respond(request, { error: "feedback_rejected", message: error.message }, 422);
    return respond(request, { ok: true, result: data });
  } catch { return respond(request, { error: "invalid_request" }, 400); }
});
