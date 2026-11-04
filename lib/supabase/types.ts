export type AppRole = "admin" | "tutor" | "student" | "customer";

export interface Profile {
  id: string;
  full_name: string;
  role: AppRole;
  avatar_url: string | null;
  created_at: string;
  account_status: "pending" | "active" | "suspended" | "deactivated";
  tutor_approved: boolean;
  student_number: string | null;
  email: string | null;
}

export interface Course {
  id: string;
  title: string;
  slug: string;
  summary: string;
  category: string;
  level: string;
  status: "draft" | "pending" | "published" | "archived";
  cover_url: string | null;
}
