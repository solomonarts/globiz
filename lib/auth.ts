import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import type { AppRole, Profile } from "@/lib/supabase/types";

export async function getProfile(): Promise<Profile | null> {
  const supabase = await createClient();
  if (!supabase) return null;
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return null;
  const { data } = await supabase.from("profiles").select("id,full_name,role,avatar_url,created_at,account_status,student_number,email,tutor_approved").eq("id", user.id).maybeSingle();
  return data as Profile | null;
}

export async function requireRole(roles: AppRole[]) {
  const profile = await getProfile();
  if (!profile) redirect("/login");
  if (profile.account_status !== "active") redirect("/account/status");
  if (!roles.includes(profile.role)) redirect(`/${profile.role}`);
  return profile;
}
