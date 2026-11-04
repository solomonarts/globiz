type ManageUserAccessAction =
  | { targetUserId: string; kind: "student_status"; status: "active" | "suspended" | "deactivated" }
  | { targetUserId: string; kind: "tutor_decision"; decision: "approved" | "changes_requested" | "rejected" | "suspended" | "deactivated" };

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const studentStatuses = new Set(["active", "suspended", "deactivated"]);
const tutorDecisions = new Set(["approved", "changes_requested", "rejected", "suspended", "deactivated"]);

export function parseManageUserAccessAction(value: unknown): ManageUserAccessAction | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const body = value as Record<string, unknown>;
  if (typeof body.targetUserId !== "string" || !uuidPattern.test(body.targetUserId)) return null;
  if (body.kind === "student_status" && typeof body.status === "string" && studentStatuses.has(body.status)) {
    return { targetUserId: body.targetUserId, kind: "student_status", status: body.status as "active" | "suspended" | "deactivated" };
  }
  if (body.kind === "tutor_decision" && typeof body.decision === "string" && tutorDecisions.has(body.decision)) {
    return { targetUserId: body.targetUserId, kind: "tutor_decision", decision: body.decision as "approved" | "changes_requested" | "rejected" | "suspended" | "deactivated" };
  }
  return null;
}

function parseAllowedOrigins(value: string | undefined) {
  return (value ?? "").split(",").map((origin) => origin.trim()).filter(Boolean);
}

function originAllowed(request: Request, allowedOrigins: string[]) {
  const origin = request.headers.get("origin");
  return !origin || allowedOrigins.includes(origin);
}

function responseHeaders(origin: string | null, allowedOrigins: string[]) {
  const headers = new Headers({ "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Vary": "Origin" });
  if (origin && allowedOrigins.includes(origin)) {
    headers.set("Access-Control-Allow-Origin", origin);
    headers.set("Access-Control-Allow-Headers", "authorization, apikey, content-type, x-client-info, idempotency-key");
    headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
    headers.set("Access-Control-Max-Age", "600");
  }
  return headers;
}

function jsonResponse(request: Request, allowedOrigins: string[], body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: responseHeaders(request.headers.get("origin"), allowedOrigins) });
}

async function sha256Hex(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function readJsonLimited(request: Request, maxBytes: number): Promise<{ ok: true; value: unknown } | { ok: false; reason: "too_large" | "invalid_json" }> {
  const reader = request.body?.getReader();
  if (!reader) return { ok: false, reason: "invalid_json" };
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) { await reader.cancel(); return { ok: false, reason: "too_large" }; }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return { ok: true, value: JSON.parse(new TextDecoder().decode(bytes)) as unknown };
  } catch {
    return { ok: false, reason: "invalid_json" };
  } finally {
    reader.releaseLock();
  }
}

if (import.meta.main) {
  const { createClient } = await import("https://esm.sh/@supabase/supabase-js@2");
  Deno.serve(async (request) => {
  const allowedOrigins = parseAllowedOrigins(Deno.env.get("APP_ALLOWED_ORIGINS"));
  const origin = request.headers.get("origin");
  if (!originAllowed(request, allowedOrigins)) {
    return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "origin_not_allowed", message: "This origin is not allowed." } }, 403);
  }
  if (request.method === "OPTIONS") return new Response("ok", { headers: responseHeaders(origin, allowedOrigins) });
  if (request.method !== "POST") {
    return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "method_not_allowed", message: "Use POST for this operation." } }, 405);
  }

  const authorization = request.headers.get("authorization");
  const token = authorization?.match(/^Bearer\s+(.+)$/i)?.[1];
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!token || !supabaseUrl || !anonKey || !serviceRoleKey) {
    return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "unauthorized", message: "A valid GlowBiz administrator session is required." } }, 401);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: authData, error: authError } = await userClient.auth.getUser(token);
  const actor = authData.user;
  if (authError || !actor) {
    return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "unauthorized", message: "A valid GlowBiz administrator session is required." } }, 401);
  }

  const { data: actorProfile, error: actorError } = await userClient.from("profiles")
    .select("role,account_status").eq("id", actor.id).maybeSingle();
  if (actorError || actorProfile?.role !== "admin" || actorProfile.account_status !== "active") {
    return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "forbidden", message: "Active administrator access is required." } }, 403);
  }

  if (request.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "application/json") {
    return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "invalid_request", message: "Send a JSON request body." } }, 415);
  }
  if (Number(request.headers.get("content-length") ?? "0") > 4096) {
    return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "invalid_request", message: "The request is too large." } }, 413);
  }
  const parsedBody = await readJsonLimited(request, 4096);
  if (!parsedBody.ok && parsedBody.reason === "too_large") {
    return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "invalid_request", message: "The request is too large." } }, 413);
  }
  const action: ManageUserAccessAction | null = parsedBody.ok ? parseManageUserAccessAction(parsedBody.value) : null;
  if (!action) {
    return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "invalid_request", message: "Choose a valid student status or tutor decision." } }, 400);
  }

  const rateKey = await sha256Hex(`manage-user-access:${actor.id}`);
  const { data: allowed, error: rateError } = await serviceClient.rpc("consume_edge_rate_limit", {
    p_rate_key: rateKey, p_limit: 30, p_window_seconds: 3600,
  });
  if (rateError) {
    console.error("manage-user-access rate limiter unavailable");
    return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "operation_failed", message: "Account access could not be updated." } }, 503);
  }
  if (!allowed) {
    return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "rate_limited", message: "Too many account changes. Try again later." } }, 429);
  }

  const expectedRole = action.kind === "student_status" ? "student" : "tutor";
  const { data: target, error: targetError } = await userClient.from("profiles")
    .select("id,role,account_status,tutor_approved,tutor_application_status")
    .eq("id", action.targetUserId).maybeSingle();
  if (targetError) {
    return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "operation_failed", message: "Account access could not be updated." } }, 500);
  }
  if (!target || target.role !== expectedRole) {
    return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "not_found", message: "The requested account was not found." } }, 404);
  }

  const nextStatus = action.kind === "student_status"
    ? action.status
    : action.decision === "suspended" ? "suspended" : action.decision === "deactivated" ? "deactivated" : "active";
  const nextApproval = action.kind === "tutor_decision" && action.decision === "approved";
  const authResult = await serviceClient.auth.admin.updateUserById(action.targetUserId, {
    ban_duration: nextStatus === "active" ? "none" : "876000h",
  });
  if (authResult.error) {
    console.error("manage-user-access auth update failed");
    return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "operation_failed", message: "Account access could not be updated." } }, 500);
  }

  const update = action.kind === "student_status"
    ? { account_status: nextStatus }
    : { account_status: nextStatus, tutor_approved: nextApproval, tutor_application_status: action.decision };
  const { data: changed, error: updateError } = await userClient.from("profiles").update(update)
    .eq("id", action.targetUserId).eq("role", expectedRole).select("id").maybeSingle();
  if (updateError || !changed) {
    const restoreBan = target.account_status === "active" ? "none" : "876000h";
    const rollback = await serviceClient.auth.admin.updateUserById(action.targetUserId, { ban_duration: restoreBan });
    if (rollback.error) console.error("manage-user-access auth rollback failed");
    console.error("manage-user-access profile update failed");
    return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "operation_failed", message: "Account access could not be updated." } }, 500);
  }

  return jsonResponse(request, allowedOrigins, { ok: true, data: { userId: action.targetUserId, status: nextStatus } });
  });
}
