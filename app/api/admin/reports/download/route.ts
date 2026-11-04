import { NextResponse } from "next/server";
import { readReportToken } from "@/lib/reports/security";
import { renderCsv, renderPdf, reportContentType, type ReportDocument } from "@/lib/reports/render";
import { createClient } from "@/lib/supabase/server";

export const runtime = "nodejs";

export async function GET(request: Request) {
  const tokenValue = new URL(request.url).searchParams.get("token");
  if (!tokenValue) return new NextResponse("Invalid or expired report link.", { status: 401 });
  const token = readReportToken(tokenValue);
  if (!token) return new NextResponse("Invalid or expired report link.", { status: 401 });

  const supabase = await createClient();
  if (!supabase) return new NextResponse("Report service is not configured.", { status: 503 });
  const { data: { user } } = await supabase.auth.getUser();
  if (!user || user.id !== token.uid) return new NextResponse("Sign in with the administrator account that requested this report.", { status: 401 });
  const { data: profile } = await supabase.from("profiles").select("role,account_status").eq("id", user.id).maybeSingle();
  if (profile?.role !== "admin" || profile.account_status !== "active") return new NextResponse("Administrator access required.", { status: 403 });

  const { data, error } = await supabase.functions.invoke("admin-reporting", { body: { operation: "generate_report", report_type: token.type, filters: token.filters } });
  if (error || !data?.report) return new NextResponse("Unable to generate this report.", { status: 400 });
  try {
    const report = data.report as ReportDocument;
    const content = token.format === "csv" ? renderCsv(report) : await renderPdf(report);
    const date = new Date(report.issued_at).toISOString().slice(0, 10);
    return new NextResponse(token.format === "csv" ? content : new Uint8Array(content), {
      headers: {
        "Content-Type": reportContentType(token.format),
        "Content-Disposition": `attachment; filename="glowbiz-${token.type}-${date}.${token.format}"`,
        "Cache-Control": "private, no-store, max-age=0",
        "X-Content-Type-Options": "nosniff",
      },
    });
  } catch {
    return new NextResponse("Unable to render this report. Check the report signing configuration.", { status: 500 });
  }
}
