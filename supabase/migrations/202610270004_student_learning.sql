alter table public.lessons
  add column if not exists description text not null default '',
  add column if not exists objectives text[] not null default '{}',
  add column if not exists instructor_notes text not null default '',
  add column if not exists practical_instructions text not null default '',
  add column if not exists safety_guidance text not null default '',
  add column if not exists lesson_type text not null default 'video_theory'
    check (lesson_type in ('video','theory','video_theory','practical','quiz','resource','live_reference'));
alter table public.assessments add column if not exists required boolean not null default false;
alter table public.assessments add column if not exists assessment_type text not null default 'written'
  check(assessment_type in ('multiple_choice','multiple_select','true_false','short_answer','written','practical','image','video','trainer_graded','rubric'));
alter table public.assessments add column if not exists max_score numeric(7,2) not null default 100 check(max_score>0);
alter table public.assessments add column if not exists max_attempts integer not null default 3 check(max_attempts>0);
alter table public.assessments add column if not exists due_at timestamptz;
alter table public.content_reviews add column if not exists reviewed_at timestamptz;
revoke insert on public.feedback from authenticated;
drop policy if exists "Approved feedback readable; insert allowed" on public.feedback;
create policy "Students read own feedback, admins moderate" on public.feedback for select to authenticated
  using(student_id=auth.uid() or public.is_admin());
drop policy if exists "Submissions visible to students and admins" on public.assessment_submissions;
create policy "Submissions visible to learner, assigned tutor, or admin" on public.assessment_submissions for select to authenticated using(
  (student_id=auth.uid() and public.is_active_user()) or public.is_admin() or exists(
    select 1 from public.assessments a join public.courses c on c.id=a.course_id join public.profiles p on p.id=auth.uid()
    where a.id=assessment_submissions.assessment_id and c.owner_id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active'
  )
);

create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null check(length(title) between 2 and 160),
  body text not null check(length(body) between 1 and 5000),
  course_id uuid references public.courses(id) on delete cascade,
  status text not null default 'draft' check(status in ('draft','published','archived')),
  published_at timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
alter table public.announcements enable row level security;
create policy "Students read published course announcements" on public.announcements for select to authenticated
  using(status='published' and (course_id is null or exists(select 1 from public.enrolments e where e.course_id=announcements.course_id and e.student_id=auth.uid() and e.status in ('active','completed'))) or public.is_admin());
create policy "Admins manage announcements" on public.announcements for all to authenticated using(public.is_admin()) with check(public.is_admin());
create index announcements_published_idx on public.announcements(published_at desc) where status='published';
create policy "Approved tutors submit lesson reviews" on public.content_reviews for insert to authenticated with check(
  submitted_by=auth.uid() and entity_type='lesson' and exists(
    select 1 from public.lessons l join public.modules m on m.id=l.module_id join public.courses c on c.id=m.course_id join public.profiles p on p.id=auth.uid()
    where l.id=entity_id and c.owner_id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active'
  )
);

create function public.admin_review_lesson_content(p_review_id uuid,p_decision text,p_reason text default '') returns boolean
language plpgsql security definer set search_path=public as $$
declare review_row public.content_reviews%rowtype;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_decision not in ('approved','changes_requested','rejected') or length(coalesce(p_reason,''))>3000 then raise exception 'Invalid content review decision'; end if;
  select * into review_row from public.content_reviews where id=p_review_id and entity_type='lesson' and decision in ('submitted','under_review');
  if review_row.id is null then raise exception 'Lesson review not found'; end if;
  update public.content_reviews set decision=p_decision,reviewer_id=auth.uid(),reason=coalesce(p_reason,''),reviewed_at=now() where id=p_review_id;
  update public.lessons set status=case when p_decision='approved' then 'published'::public.review_status when p_decision='rejected' then 'rejected'::public.review_status else 'changes_requested'::public.review_status end where id=review_row.entity_id;
  return true;
end $$;
revoke all on function public.admin_review_lesson_content(uuid,text,text) from public,anon;
grant execute on function public.admin_review_lesson_content(uuid,text,text) to authenticated;
create policy "Course tutors read learner submissions" on storage.objects for select to authenticated using(
  bucket_id='student-submissions' and exists(select 1 from public.assessments a join public.courses c on c.id=a.course_id join public.profiles p on p.id=auth.uid() where a.id=case when (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then ((storage.foldername(name))[2])::uuid else null end and c.owner_id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active')
);

create or replace function public.guard_student_assessment_attempt() returns trigger language plpgsql security definer set search_path=public
as $$
declare assessment_row public.assessments%rowtype; attempt_count integer;
begin
  if public.is_admin() then return new; end if;
  if auth.uid() is null or new.student_id<>auth.uid() or not exists(select 1 from public.profiles where id=auth.uid() and role='student' and account_status='active') then raise exception 'Active student access required'; end if;
  select * into assessment_row from public.assessments where id=new.assessment_id and status='published';
  if assessment_row.id is null or not exists(select 1 from public.enrolments e where e.student_id=auth.uid() and e.course_id=assessment_row.course_id and e.status in ('active','completed')) then raise exception 'Published assessment in an enrolled course required'; end if;
  if assessment_row.due_at is not null and assessment_row.due_at<now() then raise exception 'Assessment due date has passed'; end if;
  if nullif(trim(coalesce(new.answer,'')),'') is null and new.file_path is null then raise exception 'Provide a written answer or upload your practical work'; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':assessment:'||new.assessment_id::text,0));
  select count(*) into attempt_count from public.assessment_submissions where student_id=auth.uid() and assessment_id=new.assessment_id;
  if attempt_count>=assessment_row.max_attempts then raise exception 'Assessment attempt limit reached'; end if;
  new.score:=null;new.feedback:=null;new.reviewed_by:=null;new.reviewed_at:=null;
  return new;
end $$;
create trigger guard_student_assessment_attempt before insert on public.assessment_submissions for each row execute procedure public.guard_student_assessment_attempt();

create function public.tutor_grade_assessment_submission(p_submission_id uuid,p_score numeric,p_feedback text default '') returns boolean
language plpgsql security definer set search_path=public as $$
declare assessment_row public.assessments%rowtype;
begin
  if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and account_status='active' and (role='admin' or (role='tutor' and tutor_approved))) then raise exception 'Approved tutor or administrator access required'; end if;
  select a.* into assessment_row from public.assessments a join public.assessment_submissions s on s.assessment_id=a.id join public.courses c on c.id=a.course_id where s.id=p_submission_id and (public.is_admin() or c.owner_id=auth.uid());
  if assessment_row.id is null then raise exception 'Submission not assigned to this tutor'; end if;
  if p_score is null or p_score<0 or p_score>assessment_row.max_score or length(coalesce(p_feedback,''))>5000 then raise exception 'Score or feedback is invalid'; end if;
  update public.assessment_submissions set score=p_score,feedback=coalesce(p_feedback,''),reviewed_by=auth.uid(),reviewed_at=now() where id=p_submission_id;
  return true;
end $$;
revoke all on function public.tutor_grade_assessment_submission(uuid,numeric,text) from public,anon;
grant execute on function public.tutor_grade_assessment_submission(uuid,numeric,text) to authenticated;

create table public.learning_sessions (
  student_id uuid not null references public.profiles(id) on delete cascade,
  course_id uuid not null references public.courses(id) on delete cascade,
  module_id uuid,
  lesson_id uuid,
  video_position_seconds integer not null default 0 check(video_position_seconds >= 0),
  theory_position_percent numeric(5,2) not null default 0 check(theory_position_percent between 0 and 100),
  last_active_at timestamptz not null default now(),
  total_seconds_estimate integer not null default 0 check(total_seconds_estimate >= 0),
  primary key(student_id,course_id),
  foreign key(module_id) references public.modules(id) on delete set null,
  foreign key(lesson_id) references public.lessons(id) on delete set null
);
alter table public.learning_sessions enable row level security;
create policy "Students read own learning sessions" on public.learning_sessions for select to authenticated
  using(student_id=auth.uid() or public.is_admin());
revoke insert,update,delete on public.learning_sessions from authenticated;
drop policy if exists "Students manage own progress" on public.lesson_progress;
create policy "Students read own progress" on public.lesson_progress for select to authenticated using(student_id=auth.uid() or public.is_admin());
revoke insert,update,delete on public.lesson_progress from authenticated;

create or replace function public.guard_lesson_completion() returns trigger language plpgsql security definer set search_path=public
as $$ begin
  if new.completed_at is not null and (tg_op='INSERT' or new.completed_at is distinct from old.completed_at) and current_setting('app.lesson_completion',true) is distinct from 'allowed' and not public.is_admin() then
    raise exception 'Complete the lesson through the learning workflow';
  end if;
  return new;
end $$;
create trigger guard_lesson_completion before insert or update on public.lesson_progress for each row execute procedure public.guard_lesson_completion();

create function public.save_student_learning_position(p_course_id uuid,p_lesson_id uuid,p_video_seconds integer,p_theory_percent numeric)
returns boolean language plpgsql security definer set search_path=public as $$
declare current_session public.learning_sessions%rowtype; lesson_row record; elapsed integer:=0; max_video integer;
begin
  if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='student' and account_status='active') then raise exception 'Active student access required'; end if;
  select l.id,l.module_id,l.duration_minutes,l.lesson_type into lesson_row from public.lessons l join public.modules m on m.id=l.module_id where l.id=p_lesson_id and m.course_id=p_course_id;
  if lesson_row.id is null or not exists(select 1 from public.enrolments where student_id=auth.uid() and course_id=p_course_id and status in ('active','completed')) then raise exception 'Lesson is not in an active enrolment'; end if;
  if p_video_seconds<0 or p_theory_percent<0 or p_theory_percent>100 then raise exception 'Invalid learning position'; end if;
  select * into current_session from public.learning_sessions where student_id=auth.uid() and course_id=p_course_id;
  if found then
    elapsed:=greatest(0,extract(epoch from now()-current_session.last_active_at)::integer);
    max_video:=current_session.video_position_seconds+greatest(15,elapsed*2);
    if current_session.lesson_id=p_lesson_id and p_video_seconds>max_video then raise exception 'Video checkpoint advanced too quickly'; end if;
  elsif p_video_seconds>60 then raise exception 'Initial video checkpoint is too large';
  end if;
  insert into public.learning_sessions(student_id,course_id,module_id,lesson_id,video_position_seconds,theory_position_percent,last_active_at,total_seconds_estimate)
  values(auth.uid(),p_course_id,lesson_row.module_id,p_lesson_id,p_video_seconds,p_theory_percent,now(),0)
  on conflict(student_id,course_id) do update set module_id=excluded.module_id,lesson_id=excluded.lesson_id,
    video_position_seconds=case when public.learning_sessions.lesson_id=excluded.lesson_id then greatest(public.learning_sessions.video_position_seconds,excluded.video_position_seconds) else excluded.video_position_seconds end,
    theory_position_percent=case when public.learning_sessions.lesson_id=excluded.lesson_id then greatest(public.learning_sessions.theory_position_percent,excluded.theory_position_percent) else excluded.theory_position_percent end,
    last_active_at=now(),total_seconds_estimate=public.learning_sessions.total_seconds_estimate+least(elapsed,60);
  insert into public.lesson_progress(student_id,lesson_id,watched_seconds,updated_at) values(auth.uid(),p_lesson_id,p_video_seconds,now())
  on conflict(student_id,lesson_id) do update set watched_seconds=greatest(public.lesson_progress.watched_seconds,excluded.watched_seconds),updated_at=now();
  return true;
end $$;

create function public.student_complete_lesson(p_course_id uuid,p_lesson_id uuid,p_rating integer,p_review text default '') returns jsonb
language plpgsql security definer set search_path=public as $$
declare lesson_row record; session_row public.learning_sessions%rowtype; total_required integer; completed_required integer; pct numeric;
begin
  if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='student' and account_status='active') then raise exception 'Active student access required'; end if;
  if p_rating is null or p_rating not between 1 and 5 or length(coalesce(p_review,''))>2000 then raise exception 'A valid lesson rating is required'; end if;
  select l.id,l.module_id,l.duration_minutes,l.lesson_type,l.video_url,l.theory,m.position as module_position into lesson_row from public.lessons l join public.modules m on m.id=l.module_id where l.id=p_lesson_id and m.course_id=p_course_id;
  if lesson_row.id is null or not exists(select 1 from public.enrolments where student_id=auth.uid() and course_id=p_course_id and status='active') then raise exception 'Lesson is not available in an active enrolment'; end if;
  if exists(select 1 from public.modules prior where prior.course_id=p_course_id and prior.position<=lesson_row.module_position and exists(select 1 from public.lessons l where l.module_id=prior.id and l.required) and not exists(select 1 from public.feedback f where f.student_id=auth.uid() and f.module_id=prior.id and f.lesson_id is null) and not exists(select 1 from public.lessons l where l.module_id=prior.id and l.required and not exists(select 1 from public.lesson_progress lp where lp.student_id=auth.uid() and lp.lesson_id=l.id and lp.completed_at is not null))) then raise exception 'Submit the completed module rating before continuing'; end if;
  select * into session_row from public.learning_sessions where student_id=auth.uid() and course_id=p_course_id and lesson_id=p_lesson_id;
  if lesson_row.video_url is not null and (session_row.video_position_seconds < greatest(1,ceil(lesson_row.duration_minutes*60*0.8)::integer)) then raise exception 'Watch at least 80 percent of the lesson video first'; end if;
  if lesson_row.theory<>'' and (session_row.theory_position_percent<90) then raise exception 'Read at least 90 percent of the lesson first'; end if;
  if lesson_row.lesson_type in ('practical','quiz') then if not exists(select 1 from public.assessments a where a.course_id=p_course_id and a.required and a.status='published' and (a.module_id=lesson_row.module_id or a.module_id is null)) then raise exception 'A required assessment has not been configured for this lesson'; end if; if not exists(select 1 from public.assessment_submissions s join public.assessments a on a.id=s.assessment_id where s.student_id=auth.uid() and a.course_id=p_course_id and a.required and a.status='published' and (a.module_id=lesson_row.module_id or a.module_id is null) and s.reviewed_at is not null and s.score>=a.pass_score) then raise exception 'Complete and pass the required assessment first'; end if; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':lesson:'||p_lesson_id::text,0));
  insert into public.feedback(student_id,course_id,module_id,lesson_id,rating,body,anonymous,status)
  values(auth.uid(),p_course_id,lesson_row.module_id,p_lesson_id,p_rating,coalesce(p_review,''),true,'pending')
  on conflict(student_id,lesson_id) where lesson_id is not null do nothing;
  perform set_config('app.lesson_completion','allowed',true);
  insert into public.lesson_progress(student_id,lesson_id,completed_at,updated_at) values(auth.uid(),p_lesson_id,now(),now())
  on conflict(student_id,lesson_id) do update set completed_at=coalesce(public.lesson_progress.completed_at,now()),updated_at=now();
  perform set_config('app.lesson_completion','',true);
  select count(*) into total_required from public.lessons l join public.modules m on m.id=l.module_id where m.course_id=p_course_id and l.required;
  select count(*) into completed_required from public.lessons l join public.modules m on m.id=l.module_id join public.lesson_progress lp on lp.lesson_id=l.id and lp.student_id=auth.uid() and lp.completed_at is not null where m.course_id=p_course_id and l.required;
  pct:=case when total_required=0 then 0 else round(100.0*completed_required/total_required,1) end;
  update public.enrolments set progress=pct where student_id=auth.uid() and course_id=p_course_id;
  return jsonb_build_object('progress',pct,'required_lessons',total_required,'completed_lessons',completed_required);
end $$;

create function public.student_submit_course_feedback(p_course_id uuid,p_rating integer,p_review text default '') returns jsonb
language plpgsql security definer set search_path=public as $$
declare course_row public.courses%rowtype; progress_pct numeric; required_total integer; required_done integer;
begin
  if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='student' and account_status='active') then raise exception 'Active student access required'; end if;
  if p_rating is null or p_rating not between 1 and 5 or length(coalesce(p_review,''))>2000 then raise exception 'A valid course rating is required'; end if;
  select c.* into course_row from public.courses c join public.enrolments e on e.course_id=c.id where c.id=p_course_id and e.student_id=auth.uid() and e.status='active';
  if course_row.id is null then raise exception 'Active course enrolment required'; end if;
  select count(*) into required_total from public.lessons l join public.modules m on m.id=l.module_id where m.course_id=p_course_id and l.required;
  select count(*) into required_done from public.lessons l join public.modules m on m.id=l.module_id join public.lesson_progress lp on lp.lesson_id=l.id and lp.student_id=auth.uid() and lp.completed_at is not null where m.course_id=p_course_id and l.required;
  progress_pct:=case when required_total=0 then 0 else round(100.0*required_done/required_total,1) end;
  if progress_pct<course_row.minimum_completion then raise exception 'Required lesson completion threshold has not been met'; end if;
  if exists(select 1 from public.assessments a where a.course_id=p_course_id and a.required and a.status='published' and not exists(select 1 from public.assessment_submissions s where s.assessment_id=a.id and s.student_id=auth.uid() and s.reviewed_at is not null and s.score>=a.pass_score)) then raise exception 'Required assessment is still outstanding'; end if;
  if exists(select 1 from unnest(course_row.required_competencies) req(id) where not exists(select 1 from public.competency_records cr where cr.student_id=auth.uid() and cr.competency_id=req.id and cr.status in ('competent','mastered'))) then raise exception 'Required practical competency is still outstanding'; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':course:'||p_course_id::text,0));
  if exists(select 1 from public.feedback where student_id=auth.uid() and course_id=p_course_id and module_id is null and lesson_id is null) then raise exception 'Course feedback has already been submitted'; end if;
  insert into public.feedback(student_id,course_id,rating,body,anonymous,status) values(auth.uid(),p_course_id,p_rating,coalesce(p_review,''),true,'pending');
  update public.enrolments set progress=progress_pct,status='completed' where student_id=auth.uid() and course_id=p_course_id;
  return jsonb_build_object('progress',progress_pct,'status','completed');
end $$;

create function public.student_submit_module_feedback(p_module_id uuid,p_rating integer,p_review text default '') returns boolean
language plpgsql security definer set search_path=public as $$
declare course_key uuid; required_total integer; required_done integer;
begin
  if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and role='student' and account_status='active') then raise exception 'Active student access required'; end if;
  if p_rating is null or p_rating not between 1 and 5 or length(coalesce(p_review,''))>2000 then raise exception 'A valid module rating is required'; end if;
  select course_id into course_key from public.modules where id=p_module_id;
  if course_key is null or not exists(select 1 from public.enrolments where student_id=auth.uid() and course_id=course_key and status='active') then raise exception 'Active course enrolment required'; end if;
  select count(*) into required_total from public.lessons where module_id=p_module_id and required;
  select count(*) into required_done from public.lessons l join public.lesson_progress lp on lp.lesson_id=l.id and lp.student_id=auth.uid() and lp.completed_at is not null where l.module_id=p_module_id and l.required;
  if required_total=0 or required_done<required_total then raise exception 'Complete the required lessons in this module first'; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||':module:'||p_module_id::text,0));
  if exists(select 1 from public.feedback where student_id=auth.uid() and module_id=p_module_id and lesson_id is null) then raise exception 'Module feedback has already been submitted'; end if;
  insert into public.feedback(student_id,course_id,module_id,rating,body,anonymous,status) values(auth.uid(),course_key,p_module_id,p_rating,coalesce(p_review,''),true,'pending');
  return true;
end $$;

revoke all on function public.save_student_learning_position(uuid,uuid,integer,numeric) from public,anon;
revoke all on function public.student_complete_lesson(uuid,uuid,integer,text) from public,anon;
revoke all on function public.student_submit_course_feedback(uuid,integer,text) from public,anon;
revoke all on function public.student_submit_module_feedback(uuid,integer,text) from public,anon;
grant execute on function public.save_student_learning_position(uuid,uuid,integer,numeric) to authenticated;
grant execute on function public.student_complete_lesson(uuid,uuid,integer,text) to authenticated;
grant execute on function public.student_submit_course_feedback(uuid,integer,text) to authenticated;
grant execute on function public.student_submit_module_feedback(uuid,integer,text) to authenticated;

create index lesson_progress_student_updated_idx on public.lesson_progress(student_id,updated_at desc);
create index submissions_student_date_idx on public.assessment_submissions(student_id,submitted_at desc);
create unique index feedback_lesson_once_per_student on public.feedback(student_id,lesson_id) where lesson_id is not null;
create unique index feedback_module_once_per_student on public.feedback(student_id,module_id) where module_id is not null and lesson_id is null;
