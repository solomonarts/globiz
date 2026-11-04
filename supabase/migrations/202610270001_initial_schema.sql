create extension if not exists pgcrypto;

create type public.app_role as enum ('admin','tutor','student','customer');
create type public.review_status as enum ('draft','pending','published','archived');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '', role public.app_role not null default 'student',
  avatar_url text, phone text, location text, bio text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.programmes (
  id uuid primary key default gen_random_uuid(), title text not null, slug text not null unique,
  summary text not null default '', category text not null, status public.review_status not null default 'draft',
  created_at timestamptz not null default now()
);
create table public.courses (
  id uuid primary key default gen_random_uuid(), programme_id uuid references public.programmes(id) on delete set null,
  owner_id uuid not null references public.profiles(id), title text not null, slug text not null unique,
  summary text not null default '', category text not null, level text not null default 'beginner',
  status public.review_status not null default 'draft', cover_url text, published_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.modules (
  id uuid primary key default gen_random_uuid(), course_id uuid not null references public.courses(id) on delete cascade,
  title text not null, description text not null default '', position integer not null default 0, created_at timestamptz not null default now()
);
create table public.lessons (
  id uuid primary key default gen_random_uuid(), module_id uuid not null references public.modules(id) on delete cascade,
  title text not null, theory text not null default '', video_url text, resource_path text,
  duration_minutes integer not null default 0, position integer not null default 0,
  status public.review_status not null default 'draft', created_at timestamptz not null default now()
);
create table public.enrolments (
  id uuid primary key default gen_random_uuid(), student_id uuid not null references public.profiles(id) on delete cascade,
  course_id uuid not null references public.courses(id) on delete cascade,
  status text not null default 'active' check (status in ('pending','active','completed','withdrawn')),
  progress numeric(5,2) not null default 0 check (progress between 0 and 100), enrolled_at timestamptz not null default now(),
  created_at timestamptz not null default now(), unique(student_id,course_id)
);
create table public.lesson_progress (
  id uuid primary key default gen_random_uuid(), student_id uuid not null references public.profiles(id) on delete cascade,
  lesson_id uuid not null references public.lessons(id) on delete cascade, completed_at timestamptz,
  watched_seconds integer not null default 0, updated_at timestamptz not null default now(), unique(student_id,lesson_id)
);
create table public.assessments (
  id uuid primary key default gen_random_uuid(), course_id uuid not null references public.courses(id) on delete cascade,
  module_id uuid references public.modules(id) on delete cascade, title text not null, instructions text not null default '',
  pass_score numeric(5,2) not null default 70 check (pass_score between 0 and 100), status public.review_status not null default 'draft', created_at timestamptz not null default now()
);
create table public.assessment_submissions (
  id uuid primary key default gen_random_uuid(), assessment_id uuid not null references public.assessments(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade, answer text not null default '', file_path text,
  score numeric(5,2), feedback text, reviewed_by uuid references public.profiles(id), submitted_at timestamptz not null default now(), reviewed_at timestamptz
);
create table public.certifications (
  id uuid primary key default gen_random_uuid(), title text not null, level text not null, description text not null default '',
  course_id uuid references public.courses(id) on delete set null, created_at timestamptz not null default now()
);
create table public.certificates (
  id uuid primary key default gen_random_uuid(), certification_id uuid not null references public.certifications(id),
  student_id uuid not null references public.profiles(id) on delete cascade, course_id uuid references public.courses(id),
  certificate_number text not null unique default ('GB-' || upper(substr(encode(gen_random_bytes(8),'hex'),1,12))),
  file_path text, issued_by uuid references public.profiles(id), issued_at timestamptz not null default now(), unique(certification_id,student_id)
);
create table public.feedback (
  id uuid primary key default gen_random_uuid(), student_id uuid references public.profiles(id) on delete set null,
  course_id uuid references public.courses(id) on delete cascade, rating smallint check (rating between 1 and 5),
  body text not null, anonymous boolean not null default true,
  status text not null default 'pending' check(status in ('pending','approved','rejected')), created_at timestamptz not null default now()
);
create table public.professionals (
  id uuid primary key default gen_random_uuid(), profile_id uuid not null unique references public.profiles(id) on delete cascade,
  display_name text not null, headline text not null, category text not null, bio text not null default '',
  location text, rate_from numeric(12,2), currency text not null default 'UGX',
  status public.review_status not null default 'pending', created_at timestamptz not null default now()
);
create table public.services (
  id uuid primary key default gen_random_uuid(), professional_id uuid not null references public.professionals(id) on delete cascade,
  title text not null, description text not null default '', price numeric(12,2), duration_minutes integer not null default 60,
  active boolean not null default true, created_at timestamptz not null default now()
);
create table public.bookings (
  id uuid primary key default gen_random_uuid(), customer_id uuid not null references public.profiles(id) on delete cascade,
  professional_id uuid not null references public.professionals(id) on delete cascade,
  service_id uuid references public.services(id) on delete set null,
  scheduled_at timestamptz not null, status text not null default 'requested' check(status in ('requested','confirmed','completed','cancelled')),
  notes text not null default '', created_at timestamptz not null default now()
);
create table public.messages (
  id uuid primary key default gen_random_uuid(), booking_id uuid references public.bookings(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade, recipient_id uuid not null references public.profiles(id) on delete cascade,
  body text not null, read_at timestamptz, created_at timestamptz not null default now()
);

create function public.current_role() returns public.app_role language sql stable security definer set search_path=public
as $$ select role from public.profiles where id=auth.uid() $$;
create function public.is_admin() returns boolean language sql stable security definer set search_path=public
as $$ select coalesce(public.current_role()='admin',false) $$;
create function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public
as $$ begin insert into public.profiles(id,full_name,role) values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''),
  case when new.raw_user_meta_data->>'role' in ('student','tutor','customer') then (new.raw_user_meta_data->>'role')::public.app_role else 'student'::public.app_role end); return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

-- Role and approval flags are managed by administrators, never by profile owners.
create function public.protect_profile_permissions() returns trigger language plpgsql security definer set search_path=public
as $$ begin
  if auth.uid() is not null and not public.is_admin() and (new.role is distinct from old.role or new.tutor_approved is distinct from old.tutor_approved) then
    raise exception 'Only administrators can change account permissions';
  end if;
  return new;
end $$;
alter table public.profiles add column tutor_approved boolean not null default false;
create trigger protect_profile_permissions before update on public.profiles for each row execute procedure public.protect_profile_permissions();
create function public.prevent_unapproved_publishing() returns trigger language plpgsql security definer set search_path=public
as $$ begin
  if auth.uid() is not null and not public.is_admin() and to_jsonb(new)->>'status' in ('published','approved') then
    raise exception 'Only administrators can approve or publish this content';
  end if;
  return new;
end $$;
create trigger courses_require_approval before insert or update on public.courses for each row execute procedure public.prevent_unapproved_publishing();
create trigger professionals_require_approval before insert or update on public.professionals for each row execute procedure public.prevent_unapproved_publishing();
create trigger feedback_requires_moderation before insert or update on public.feedback for each row execute procedure public.prevent_unapproved_publishing();

alter table public.profiles enable row level security;
alter table public.programmes enable row level security;
alter table public.courses enable row level security;
alter table public.modules enable row level security;
alter table public.lessons enable row level security;
alter table public.enrolments enable row level security;
alter table public.lesson_progress enable row level security;
alter table public.assessments enable row level security;
alter table public.assessment_submissions enable row level security;
alter table public.certifications enable row level security;
alter table public.certificates enable row level security;
alter table public.feedback enable row level security;
alter table public.professionals enable row level security;
alter table public.services enable row level security;
alter table public.bookings enable row level security;
alter table public.messages enable row level security;

create policy "Profile read self or admin" on public.profiles for select to authenticated using(id=auth.uid() or public.is_admin());
create policy "Profile update self or admin" on public.profiles for update to authenticated using(id=auth.uid() or public.is_admin()) with check(id=auth.uid() or public.is_admin());
create policy "Published programmes readable" on public.programmes for select using(status='published' or public.is_admin());
create policy "Admins manage programmes" on public.programmes for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Published courses readable" on public.courses for select using(status='published' or owner_id=auth.uid() or public.is_admin());
create policy "Tutors manage own courses" on public.courses for all to authenticated using((owner_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='tutor' and p.tutor_approved)) or public.is_admin()) with check((owner_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='tutor' and p.tutor_approved)) or public.is_admin());
create policy "Modules follow course access" on public.modules for select using(exists(select 1 from public.courses c where c.id=course_id and (c.status='published' or c.owner_id=auth.uid() or public.is_admin())));
create policy "Course owners manage modules" on public.modules for all to authenticated using(exists(select 1 from public.courses c where c.id=course_id and (c.owner_id=auth.uid() or public.is_admin()))) with check(exists(select 1 from public.courses c where c.id=course_id and (c.owner_id=auth.uid() or public.is_admin())));
create policy "Lessons follow course access" on public.lessons for select using(exists(select 1 from public.modules m join public.courses c on c.id=m.course_id where m.id=module_id and (c.status='published' or c.owner_id=auth.uid() or public.is_admin())));
create policy "Course owners manage lessons" on public.lessons for all to authenticated using(exists(select 1 from public.modules m join public.courses c on c.id=m.course_id where m.id=module_id and (c.owner_id=auth.uid() or public.is_admin()))) with check(exists(select 1 from public.modules m join public.courses c on c.id=m.course_id where m.id=module_id and (c.owner_id=auth.uid() or public.is_admin())));
create policy "Students see own enrolments" on public.enrolments for select to authenticated using(student_id=auth.uid() or public.is_admin() or exists(select 1 from public.courses c where c.id=course_id and c.owner_id=auth.uid()));
create policy "Students enrol self" on public.enrolments for insert to authenticated with check(student_id=auth.uid() and public.current_role()='student' and status in ('pending','active'));
create policy "Admins manage enrolments" on public.enrolments for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Students manage own progress" on public.lesson_progress for all to authenticated using(student_id=auth.uid() or public.is_admin()) with check(student_id=auth.uid() or public.is_admin());
create policy "Assessments visible to learners and tutors" on public.assessments for select using(exists(select 1 from public.courses c where c.id=course_id and (c.status='published' or c.owner_id=auth.uid() or public.is_admin())));
create policy "Course owners manage assessments" on public.assessments for all to authenticated using(exists(select 1 from public.courses c where c.id=course_id and (c.owner_id=auth.uid() or public.is_admin()))) with check(exists(select 1 from public.courses c where c.id=course_id and (c.owner_id=auth.uid() or public.is_admin())));
create policy "Submissions visible to student or course tutor" on public.assessment_submissions for select to authenticated using(student_id=auth.uid() or public.is_admin() or exists(select 1 from public.assessments a join public.courses c on c.id=a.course_id where a.id=assessment_id and c.owner_id=auth.uid()));
create policy "Students submit assessments" on public.assessment_submissions for insert to authenticated with check(student_id=auth.uid());
create policy "Tutors review submissions" on public.assessment_submissions for update to authenticated using(public.is_admin() or exists(select 1 from public.assessments a join public.courses c on c.id=a.course_id where a.id=assessment_id and c.owner_id=auth.uid())) with check(public.is_admin() or exists(select 1 from public.assessments a join public.courses c on c.id=a.course_id where a.id=assessment_id and c.owner_id=auth.uid()));
create policy "Certifications readable" on public.certifications for select using(true);
create policy "Admins manage certifications" on public.certifications for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Certificates owner or admin" on public.certificates for select to authenticated using(student_id=auth.uid() or public.is_admin());
create policy "Admins issue certificates" on public.certificates for insert to authenticated with check(public.is_admin());
create policy "Approved feedback readable; insert allowed" on public.feedback for select using(status='approved' or student_id=auth.uid() or public.is_admin());
create policy "Students submit feedback" on public.feedback for insert to authenticated with check(student_id=auth.uid() or student_id is null);
create policy "Admins moderate feedback" on public.feedback for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Published professionals readable" on public.professionals for select using(status='published' or profile_id=auth.uid() or public.is_admin());
create policy "Professionals edit own profile" on public.professionals for all to authenticated using(profile_id=auth.uid() or public.is_admin()) with check(profile_id=auth.uid() or public.is_admin());
create policy "Active services readable" on public.services for select using(active and exists(select 1 from public.professionals p where p.id=professional_id and p.status='published') or public.is_admin());
create policy "Professional manages own services" on public.services for all to authenticated using(exists(select 1 from public.professionals p where p.id=professional_id and (p.profile_id=auth.uid() or public.is_admin()))) with check(exists(select 1 from public.professionals p where p.id=professional_id and (p.profile_id=auth.uid() or public.is_admin())));
create policy "Bookings visible to involved parties" on public.bookings for select to authenticated using(customer_id=auth.uid() or exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid()) or public.is_admin());
create policy "Customers request bookings" on public.bookings for insert to authenticated with check(customer_id=auth.uid() and public.current_role()='customer');
create policy "Booking parties update bookings" on public.bookings for update to authenticated using(customer_id=auth.uid() or exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid()) or public.is_admin()) with check(customer_id=auth.uid() or exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid()) or public.is_admin());
create policy "Message participants read" on public.messages for select to authenticated using(sender_id=auth.uid() or recipient_id=auth.uid() or public.is_admin());
create policy "Message participants send" on public.messages for insert to authenticated with check(sender_id=auth.uid() and exists(select 1 from public.bookings b join public.professionals p on p.id=b.professional_id where b.id=booking_id and ((b.customer_id=auth.uid() and p.profile_id=recipient_id) or (p.profile_id=auth.uid() and b.customer_id=recipient_id))));
create policy "Recipients mark read" on public.messages for update to authenticated using(recipient_id=auth.uid() or public.is_admin()) with check(recipient_id=auth.uid() or public.is_admin());

create index enrolments_student_idx on public.enrolments(student_id,created_at desc);
create index enrolments_course_idx on public.enrolments(course_id,status);
create index lessons_module_position_idx on public.lessons(module_id,position);
create index submissions_review_idx on public.assessment_submissions(reviewed_at,submitted_at desc);
create index bookings_status_idx on public.bookings(status,scheduled_at);
create index feedback_status_idx on public.feedback(status,created_at desc);
create index professionals_public_idx on public.professionals(status,category);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
 ('lesson-resources','lesson-resources',false,52428800,array['application/pdf','video/mp4','image/jpeg','image/png','application/vnd.openxmlformats-officedocument.wordprocessingml.document']),
 ('profile-images','profile-images',true,5242880,array['image/jpeg','image/png','image/webp']),
 ('student-submissions','student-submissions',false,20971520,array['application/pdf','image/jpeg','image/png','video/mp4']),
 ('certificates','certificates',false,10485760,array['application/pdf']) on conflict(id) do nothing;
create policy "Public profile images are viewable" on storage.objects for select using(bucket_id='profile-images');
create policy "Users upload own profile image" on storage.objects for insert to authenticated with check(bucket_id='profile-images' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "Authenticated users upload submissions" on storage.objects for insert to authenticated with check(bucket_id='student-submissions' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "Users access own submissions" on storage.objects for select to authenticated using(bucket_id='student-submissions' and (storage.foldername(name))[1]=auth.uid()::text or public.is_admin());
create policy "Tutor uploads lesson resources" on storage.objects for insert to authenticated with check(bucket_id='lesson-resources' and (storage.foldername(name))[1]=auth.uid()::text and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='tutor' and p.tutor_approved));
create policy "Course members read lesson resources" on storage.objects for select to authenticated using(bucket_id='lesson-resources' and (public.is_admin() or (storage.foldername(name))[1]=auth.uid()::text or exists(select 1 from public.lessons l join public.modules m on m.id=l.module_id join public.courses c on c.id=m.course_id left join public.enrolments e on e.course_id=c.id where l.resource_path=name and (c.owner_id=auth.uid() or e.student_id=auth.uid()))));
create policy "Tutors update own lesson resources" on storage.objects for update to authenticated using(bucket_id='lesson-resources' and (storage.foldername(name))[1]=auth.uid()::text and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='tutor' and p.tutor_approved)) with check(bucket_id='lesson-resources' and (storage.foldername(name))[1]=auth.uid()::text and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='tutor' and p.tutor_approved));
create policy "Certificate owner or admin can download" on storage.objects for select to authenticated using(bucket_id='certificates' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin()));
