import { redirect } from "next/navigation";
import { ClipboardList, Clock3, Upload } from "lucide-react";
import { submitAssessmentAttempt } from "@/app/actions";
import { getProfile } from "@/lib/auth";
import { createClient } from "@/lib/supabase/server";

type Assessment = {
  id: string;
  title: string;
  instructions: string;
  assessment_type: string;
  pass_score: number;
  max_score: number;
  max_attempts: number;
  due_at: string | null;
  criteria: unknown;
  courses: { title: string } | null;
  modules: { title: string } | null;
};

type Attempt = {
  id: string;
  assessment_id: string;
  answer: string;
  file_path: string | null;
  score: number | null;
  feedback: string | null;
  submitted_at: string;
  reviewed_at: string | null;
  assessments: { title: string; pass_score: number; max_score: number } | null;
};

export default async function StudentAssessments({
  searchParams,
}: {
  searchParams: Promise<{ message?: string; error?: string }>;
}) {
  const [profile, notice] = await Promise.all([getProfile(), searchParams]);
  if (!profile) redirect("/login");
  if (profile.role !== "student" || profile.account_status !== "active") {
    redirect(`/${profile.role}`);
  }

  const supabase = await createClient();
  if (!supabase) redirect("/student");

  const { data: payload, error } = await supabase.functions.invoke("student-assessments", {
    method: "GET",
  });
  if (error) redirect("/student/assessments?error=Unable+to+load+assessments");

  const assessments = (payload?.assessments ?? []) as Assessment[];
  const attempts = (payload?.attempts ?? []) as Attempt[];

  return (
    <main style={{ minHeight: "100vh", background: "#f8faf7" }}>
      <section style={{ maxWidth: 960, margin: "auto", padding: "32px 22px 56px" }}>
        <div className="pill"><ClipboardList size={13} /> ASSESSMENTS</div>
        <h1 className="serif" style={{ fontSize: 34, fontWeight: 500, margin: "12px 0 5px" }}>
          Assignments and results
        </h1>
        <p style={{ fontSize: 13, color: "#829087", lineHeight: 1.6 }}>
          Read the instructions and submit written answers or practical work. Tutors grade submissions; your score and feedback appear here after review.
        </p>

        {notice.error && <p role="alert" style={{ fontSize: 12, color: "#a44235" }}>{notice.error}</p>}
        {notice.message && <p role="status" style={{ fontSize: 12, color: "#176b4d" }}>{notice.message}</p>}

        <div style={{ display: "grid", gap: 14, marginTop: 17 }}>
          {assessments.map((assessment) => {
            const history = attempts.filter((attempt) => attempt.assessment_id === assessment.id);
            const exhausted = history.length >= assessment.max_attempts;
            const overdue = Boolean(
              assessment.due_at && new Date(assessment.due_at).getTime() < Date.now(),
            );

            return (
              <article className="card" key={assessment.id} style={{ padding: 20 }}>
                <div style={{ display: "flex", justifyContent: "space-between", gap: 12, flexWrap: "wrap" }}>
                  <div>
                    <h2 style={{ fontSize: 17, margin: "0 0 5px" }}>{assessment.title}</h2>
                    <div style={{ fontSize: 11, color: "#829087" }}>
                      {assessment.courses?.title ?? "Course"}
                      {assessment.modules?.title ? ` · ${assessment.modules.title}` : ""}
                      {` · ${assessment.assessment_type.replaceAll("_", " ")}`}
                    </div>
                  </div>
                  <span className="pill">{history.length}/{assessment.max_attempts} attempts</span>
                </div>

                <p style={{ fontSize: 12, lineHeight: 1.7, color: "#536158", whiteSpace: "pre-wrap" }}>
                  {assessment.instructions || "Follow the assignment brief and submit your work below."}
                </p>

                <div style={{ display: "flex", gap: 12, fontSize: 11, color: "#718078", flexWrap: "wrap" }}>
                  <span>Pass threshold: {assessment.pass_score}%</span>
                  <span>Maximum score: {assessment.max_score}</span>
                  {assessment.due_at ? (
                    <span>
                      <Clock3 size={12} style={{ verticalAlign: "middle" }} /> Due{" "}
                      {new Date(assessment.due_at).toLocaleString("en-UG")}
                    </span>
                  ) : null}
                </div>

                {Array.isArray(assessment.criteria) && assessment.criteria.length > 0 ? (
                  <details style={{ marginTop: 10, fontSize: 12 }}>
                    <summary>Assessment rubric</summary>
                    <pre style={{ whiteSpace: "pre-wrap", fontFamily: "inherit", color: "#657168" }}>
                      {JSON.stringify(assessment.criteria, null, 2)}
                    </pre>
                  </details>
                ) : null}

                {!overdue && !exhausted ? (
                  <form
                    action={submitAssessmentAttempt}
                    encType="multipart/form-data"
                    className="assessment-form"
                    style={{ display: "grid", gap: 10, marginTop: 15, borderTop: "1px solid #edf0ed", paddingTop: 15 }}
                  >
                    <input type="hidden" name="assessmentId" value={assessment.id} />
                    <label style={label}>
                      Written answer
                      <textarea className="input" name="answer" maxLength={20000} rows={4} placeholder="Write your answer or describe your practical work." />
                    </label>
                    <label style={label}>
                      Attach practical work <small>PDF, JPG, PNG, or MP4, up to 20 MB</small>
                      <input type="file" name="submission" className="input" accept="application/pdf,image/jpeg,image/png,video/mp4" />
                    </label>
                    <button className="btn" style={{ justifySelf: "start" }}>
                      <Upload size={14} /> Submit attempt
                    </button>
                  </form>
                ) : (
                  <p style={{ fontSize: 12, color: "#9a692c" }}>
                    {overdue ? "The due date has passed." : "You have used all available attempts."}
                  </p>
                )}

                {history.length > 0 ? (
                  <div style={{ marginTop: 16 }}>
                    <h3 style={{ fontSize: 13 }}>Your attempts</h3>
                    {history.map((attempt, index) => (
                      <div key={attempt.id} style={{ padding: "10px 0", borderTop: "1px solid #edf0ed", fontSize: 11 }}>
                        <b>Attempt {history.length - index}</b> · {new Date(attempt.submitted_at).toLocaleString("en-UG")} ·{" "}
                        {attempt.reviewed_at ? `Score ${attempt.score ?? "—"}%` : "Awaiting tutor review"}
                        {attempt.feedback ? <p style={{ fontSize: 12, color: "#5d6a61", margin: "5px 0 0" }}>{attempt.feedback}</p> : null}
                      </div>
                    ))}
                  </div>
                ) : null}
              </article>
            );
          })}

          {assessments.length === 0 ? (
            <div className="card" style={{ padding: 30, textAlign: "center", fontSize: 13, color: "#829087" }}>
              No published assessments are available for your enrolled courses.
            </div>
          ) : null}
        </div>
      </section>
      <style>{"@media(max-width:640px){.assessment-form{grid-template-columns:1fr!important}}"}</style>
    </main>
  );
}

const label = { display: "grid", gap: 6, fontSize: 11, color: "#718078" } as const;
