type InviteRole = "student" | "tutor" | "customer";
type InviteInput = { email: string; fullName: string; role: InviteRole; qualifications: string; phone: string; location: string };

const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function parseInviteInput(value: unknown): InviteInput | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const body = value as Record<string, unknown>;
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  const fullName = typeof body.fullName === "string" ? body.fullName.trim() : "";
  const role = body.role;
  const qualifications = typeof body.qualifications === "string" ? body.qualifications.trim() : "";
  const phone = typeof body.phone === "string" ? body.phone.trim() : "";
  const location = typeof body.location === "string" ? body.location.trim() : "";
  if (!emailPattern.test(email) || email.length > 254 || fullName.length < 2 || fullName.length > 120) return null;
  if (role !== "student" && role !== "tutor" && role !== "customer") return null;
  if (qualifications.length > 2000 || phone.length > 40 || location.length > 120) return null;
  return { email, fullName, role, qualifications, phone, location };
}

function parseAllowedOrigins(value: string | undefined) {
  return (value ?? "").split(",").map((origin) => origin.trim()).filter(Boolean);
}

function responseHeaders(origin: string | null, allowedOrigins: string[]) {
  const headers = new Headers({ "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Vary": "Origin" });
  if (origin && allowedOrigins.includes(origin)) {
    headers.set("Access-Control-Allow-Origin", origin);
    headers.set("Access-Control-Allow-Headers", "authorization, apikey, content-type, x-client-info");
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

async function readJsonLimited(request: Request, maxBytes: number): Promise<{ ok: true; value: unknown } | { ok: false; tooLarge: boolean }> {
  const reader = request.body?.getReader();
  if (!reader) return { ok: false, tooLarge: false };
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) { await reader.cancel(); return { ok: false, tooLarge: true }; }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return { ok: true, value: JSON.parse(new TextDecoder().decode(bytes)) as unknown };
  } catch {
    return { ok: false, tooLarge: false };
  } finally {
    reader.releaseLock();
  }
}

if (import.meta.main) {
  const { createClient } = await import("https://esm.sh/@supabase/supabase-js@2");
  Deno.serve(async (request) => {
    const allowedOrigins = parseAllowedOrigins(Deno.env.get("APP_ALLOWED_ORIGINS"));
    const origin = request.headers.get("origin");
    if (origin && !allowedOrigins.includes(origin)) return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "origin_not_allowed", message: "This origin is not allowed." } }, 403);
    if (request.method === "OPTIONS") return new Response("ok", { headers: responseHeaders(origin, allowedOrigins) });
    if (request.method !== "POST") return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "method_not_allowed", message: "Use POST for this operation." } }, 405);
    if (request.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "application/json") return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "invalid_request", message: "Send a JSON request body." } }, 415);

    const token = request.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1];
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const siteUrlValue = Deno.env.get("APP_SITE_URL");
    if (!token || !supabaseUrl || !anonKey || !serviceRoleKey || !siteUrlValue) return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "not_configured", message: "The invitation service is not configured." } }, 503);

    let siteUrl: URL;
    try { siteUrl = new URL(siteUrlValue); } catch { return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "not_configured", message: "The invitation service is not configured." } }, 503); }
    if (!allowedOrigins.includes(siteUrl.origin)) return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "not_configured", message: "The invitation redirect origin is not allowed." } }, 503);

    const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { autoRefreshToken: false, persistSession: false } });
    const serviceClient = createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } });
    const { data: authData, error: authError } = await userClient.auth.getUser(token);
    if (authError || !authData.user) return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "unauthorized", message: "An active administrator session is required." } }, 401);
    const { data: actorProfile } = await userClient.from("profiles").select("role,account_status").eq("id", authData.user.id).maybeSingle();
    if (actorProfile?.role !== "admin" || actorProfile.account_status !== "active") return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "forbidden", message: "Active administrator access is required." } }, 403);

    if (Number(request.headers.get("content-length") ?? "0") > 4096) return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "invalid_request", message: "The request is too large." } }, 413);
    const parsedBody = await readJsonLimited(request, 4096);
    if (!parsedBody.ok) return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "invalid_request", message: parsedBody.tooLarge ? "The request is too large." : "Send a valid JSON invitation." } }, parsedBody.tooLarge ? 413 : 400);
    const invite = parseInviteInput(parsedBody.value);
    if (!invite) return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "invalid_request", message: "Check the name, email, role and invitation details." } }, 400);

    const rateKey = await sha256Hex(`invite-platform-user:${authData.user.id}`);
    const { data: rateAllowed, error: rateError } = await serviceClient.rpc("consume_edge_rate_limit", { p_rate_key: rateKey, p_limit: 20, p_window_seconds: 3600 });
    if (rateError) return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "operation_failed", message: "The invitation could not be sent." } }, 503);
    if (!rateAllowed) return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "rate_limited", message: "Too many invitations. Try again later." } }, 429);

    const redirectTo = new URL("/auth/callback?next=/account/activate", siteUrl).toString();
    const { data: invited, error: inviteError } = await serviceClient.auth.admin.inviteUserByEmail(invite.email, {
      data: { full_name: invite.fullName, role: invite.role, qualification_summary: invite.qualifications },
      redirectTo,
    });
    if (inviteError || !invited.user) return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "operation_failed", message: "The invitation could not be sent. Check the email and Supabase mail settings." } }, 400);

    const initialProfile = invite.role === "student"
      ? { account_status: "pending", phone: invite.phone || null, location: invite.location || null }
      : { phone: invite.phone || null, location: invite.location || null };
    const { error: profileError } = await serviceClient.from("profiles").update(initialProfile).eq("id", invited.user.id);
    const { error: auditError } = profileError ? { error: profileError } : await serviceClient.from("audit_logs").insert({
      actor_id: authData.user.id,
      action: `INVITE_${invite.role.toUpperCase()}`,
      entity_type: "profiles",
      entity_id: invited.user.id,
      details: { invite_sent: true },
    });
    if (profileError || auditError) {
      await serviceClient.auth.admin.deleteUser(invited.user.id);
      console.error("invite-platform-user profile or audit write failed");
      return jsonResponse(request, allowedOrigins, { ok: false, error: { code: "operation_failed", message: "The invitation could not be completed." } }, 500);
    }
    return jsonResponse(request, allowedOrigins, { ok: true, data: { userId: invited.user.id, role: invite.role, status: invite.role === "student" ? "pending" : "active" } }, 201);
  });
}
