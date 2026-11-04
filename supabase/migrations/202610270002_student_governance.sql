create type public.account_status as enum ('pending','active','suspended','deactivated');
alter type public.review_status add value if not exists 'under_review';
alter type public.review_status add value if not exists 'changes_requested';
alter type public.review_status add value if not exists 'approved';
alter type public.review_status add value if not exists 'rejected';

alter table public.profiles add column account_status public.account_status not null default 'active';
alter table public.profiles add column email text;
create unique index profiles_email_unique on public.profiles(lower(email)) where email is not null;
alter table public.profiles add column student_number text unique;
alter table public.profiles add column accessibility_preferences jsonb not null default '{}'::jsonb;
alter table public.profiles add column qualification_summary text not null default '';
alter table public.profiles add column tutor_application_status text not null default 'pending' check(tutor_application_status in ('pending','approved','changes_requested','rejected','suspended','deactivated'));
update public.profiles set student_number='GBS-'||upper(substr(replace(id::text,'-',''),1,10)) where role='student' and student_number is null;
update public.profiles p set email=u.email from auth.users u where u.id=p.id and p.email is null;
update public.profiles set account_status='pending' where role='student';
create index profiles_student_status_idx on public.profiles(role,account_status,created_at desc);

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public
as $$ begin
  insert into public.profiles(id,full_name,email,role,account_status,student_number,qualification_summary,tutor_application_status)
  values(new.id,coalesce(new.raw_user_meta_data->>'full_name',''),new.email,
    case when new.raw_user_meta_data->>'role' in ('student','tutor','customer') then (new.raw_user_meta_data->>'role')::public.app_role else 'student'::public.app_role end,
    case when coalesce(new.raw_user_meta_data->>'role','student')='student' then 'pending'::public.account_status else 'active'::public.account_status end,
    case when coalesce(new.raw_user_meta_data->>'role','student')='student' then 'GBS-'||upper(substr(replace(new.id::text,'-',''),1,10)) else null end,
    coalesce(new.raw_user_meta_data->>'qualification_summary',''),
    case when coalesce(new.raw_user_meta_data->>'role','')='tutor' then 'pending' else 'approved' end);
  return new;
end $$;
create function public.sync_profile_email() returns trigger language plpgsql security definer set search_path=public
as $$ begin update public.profiles set email=new.email where id=new.id; return new; end $$;
create trigger sync_profile_email after update of email on auth.users for each row when(old.email is distinct from new.email) execute procedure public.sync_profile_email();

create table public.learning_groups (
 id uuid primary key default gen_random_uuid(), name text not null, programme_id uuid references public.programmes(id) on delete set null,
 course_id uuid references public.courses(id) on delete set null, starts_on date, ends_on date,
 status text not null default 'active' check(status in ('planned','active','completed','archived')),
 created_by uuid references public.profiles(id), created_at timestamptz not null default now()
);
create table public.group_members (
 group_id uuid not null references public.learning_groups(id) on delete cascade,
 student_id uuid not null references public.profiles(id) on delete cascade,
 assigned_by uuid references public.profiles(id), assigned_at timestamptz not null default now(),
 primary key(group_id,student_id)
);
create table public.admin_student_notes (
 id uuid primary key default gen_random_uuid(), student_id uuid not null references public.profiles(id) on delete cascade,
 author_id uuid not null references public.profiles(id), note text not null check(length(note) between 1 and 5000),
 created_at timestamptz not null default now()
);
create table public.audit_logs (
 id bigint generated always as identity primary key, actor_id uuid references public.profiles(id) on delete set null,
 action text not null, entity_type text not null, entity_id uuid, details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
create index audit_logs_entity_idx on public.audit_logs(entity_type,entity_id,created_at desc);
create index audit_logs_actor_idx on public.audit_logs(actor_id,created_at desc);

alter table public.enrolments add column approved_by uuid references public.profiles(id);
alter table public.enrolments add column reviewed_at timestamptz;
alter table public.enrolments alter column status set default 'pending';
create table public.certification_levels (
 id uuid primary key default gen_random_uuid(), programme_id uuid references public.programmes(id) on delete cascade,
 course_id uuid references public.courses(id) on delete cascade, name text not null, description text not null default '',
 position integer not null default 0, is_completion_credential boolean not null default false,
 created_at timestamptz not null default now(), check(programme_id is not null or course_id is not null)
);
create table public.competencies (
 id uuid primary key default gen_random_uuid(), course_id uuid not null references public.courses(id) on delete cascade,
 code text not null, title text not null, description text not null default '', created_at timestamptz not null default now(), unique(course_id,code)
);
create table public.competency_records (
 id uuid primary key default gen_random_uuid(), student_id uuid not null references public.profiles(id) on delete cascade,
 competency_id uuid not null references public.competencies(id) on delete cascade,
 assessed_by uuid references public.profiles(id), assessment_submission_id uuid references public.assessment_submissions(id) on delete set null,
 status text not null check(status in ('not_yet','developing','competent','mastered')),
 evidence text not null default '', assessed_at timestamptz not null default now()
);
create table public.certification_applications (
 id uuid primary key default gen_random_uuid(), student_id uuid not null references public.profiles(id) on delete cascade,
 certification_id uuid not null references public.certifications(id), course_id uuid references public.courses(id),
 recommended_by uuid references public.profiles(id), status text not null default 'pending_tutor'
 check(status in ('pending_tutor','pending_admin','changes_requested','approved','rejected')),
 reviewed_by uuid references public.profiles(id), reviewed_at timestamptz,
 certificate_id uuid references public.certificates(id), created_at timestamptz not null default now()
);
create table public.certification_application_reviews (
 id uuid primary key default gen_random_uuid(), application_id uuid not null references public.certification_applications(id) on delete cascade,
 reviewer_id uuid not null references public.profiles(id), reviewer_role text not null check(reviewer_role in ('tutor','admin')),
 decision text not null check(decision in ('recommended','approved','rejected','changes_requested')),
 private_notes text not null default '', evidence_request text not null default '', created_at timestamptz not null default now()
);
alter table public.certificates add column certification_level_id uuid references public.certification_levels(id);
alter table public.certificates add column curriculum_version integer not null default 1;
alter table public.certificates add column revoked_at timestamptz;
alter table public.certificates add column revocation_reason text;
alter table public.certificates add column replaced_by uuid references public.certificates(id);
alter table public.certificates drop constraint if exists certificates_certification_id_student_id_key;
create unique index certificates_active_identity on public.certificates(certification_id,student_id) where revoked_at is null;
create table public.course_versions (
 id uuid primary key default gen_random_uuid(), course_id uuid not null references public.courses(id) on delete cascade,
 version integer not null, snapshot jsonb not null, created_by uuid references public.profiles(id),
 approved_by uuid references public.profiles(id), approved_at timestamptz, created_at timestamptz not null default now(),
 unique(course_id,version)
);
alter table public.courses add column current_version integer not null default 1;
alter table public.courses add column enrolment_open boolean not null default true;
alter table public.courses add column minimum_completion numeric(5,2) not null default 100 check(minimum_completion between 0 and 100);
alter table public.courses add column required_competencies uuid[] not null default '{}';
alter table public.assessments add column practical_required boolean not null default false;
alter table public.assessments add column criteria jsonb not null default '[]'::jsonb;
alter table public.assessments add column prerequisite_module_id uuid references public.modules(id);
alter table public.lessons add column required boolean not null default true;

alter table public.feedback add column module_id uuid references public.modules(id) on delete set null;
alter table public.feedback add column lesson_id uuid references public.lessons(id) on delete set null;
alter table public.feedback add column assigned_tutor_id uuid references public.profiles(id) on delete set null;
alter table public.feedback add column internal_admin_notes text;
alter table public.feedback add column resolution_status text not null default 'open' check(resolution_status in ('open','investigating','resolved','dismissed'));
alter table public.feedback add column redacted_body text;
alter table public.feedback add column flagged boolean not null default false;

create table public.content_reviews (
 id uuid primary key default gen_random_uuid(), entity_type text not null check(entity_type in ('course','module','lesson','assessment')),
 entity_id uuid not null, submitted_by uuid references public.profiles(id), reviewer_id uuid references public.profiles(id),
 decision text not null check(decision in ('submitted','under_review','changes_requested','approved','rejected','published')),
 reason text, version integer not null default 1, created_at timestamptz not null default now()
);
create index content_reviews_entity_idx on public.content_reviews(entity_type,entity_id,created_at desc);

create or replace function public.is_active_user() returns boolean language sql stable security definer set search_path=public
as $$ select coalesce((select account_status='active' from public.profiles where id=auth.uid()),false) $$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public
as $$ select coalesce((select role='admin' and account_status='active' from public.profiles where id=auth.uid()),false) $$;
create or replace function public.protect_profile_permissions() returns trigger language plpgsql security definer set search_path=public
as $$ begin
 if auth.uid() is not null and not public.is_admin() and (
   new.role is distinct from old.role or new.tutor_approved is distinct from old.tutor_approved or
   new.account_status is distinct from old.account_status or new.tutor_application_status is distinct from old.tutor_application_status or
   new.student_number is distinct from old.student_number
 ) then raise exception 'Only administrators can change account permissions or student identifiers'; end if;
 return new;
end $$;
create function public.admin_review_certification(p_application_id uuid,p_decision text,p_private_notes text default '',p_evidence_request text default '') returns jsonb language plpgsql security definer set search_path=public
as $$ declare app public.certification_applications%rowtype; course public.courses%rowtype; cert_id uuid; cert_number text; begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 if p_decision not in ('approved','rejected','changes_requested') then raise exception 'Invalid certification decision'; end if;
 select * into app from public.certification_applications where id=p_application_id for update;
 if app.id is null or app.status not in ('pending_admin','changes_requested') then raise exception 'Application is not awaiting administrator review'; end if;
 if p_decision='approved' then
  if app.course_id is null then raise exception 'Application has no course'; end if;
  if not exists(select 1 from public.profiles p where p.id=app.student_id and p.role='student' and p.account_status='active') then raise exception 'Student account is not active'; end if;
  select * into course from public.courses where id=app.course_id;
  if course.id is null then raise exception 'Course was not found'; end if;
  if exists(select 1 from public.certifications cr where cr.id=app.certification_id and cr.course_id is not null and cr.course_id<>app.course_id) then raise exception 'Certification does not match the course'; end if;
  if not exists(select 1 from public.enrolments e where e.student_id=app.student_id and e.course_id=app.course_id and (e.status='completed' or e.progress>=course.minimum_completion)) then raise exception 'Course completion requirements are not met'; end if;
  if exists(select 1 from public.assessments a where a.course_id=app.course_id and a.status='published' and not exists(select 1 from public.assessment_submissions s where s.assessment_id=a.id and s.student_id=app.student_id and s.score>=a.pass_score)) then raise exception 'A required assessment has not been passed'; end if;
  if exists(select 1 from unnest(course.required_competencies) required(id) where not exists(select 1 from public.competency_records cr where cr.student_id=app.student_id and cr.competency_id=required.id and cr.status in ('competent','mastered'))) then raise exception 'A required competency is missing'; end if;
  if exists(select 1 from public.certificates c where c.student_id=app.student_id and c.certification_id=app.certification_id and c.revoked_at is null) then raise exception 'An active certificate already exists'; end if;
  insert into public.certificates(student_id,certification_id,course_id,issued_by,curriculum_version) values(app.student_id,app.certification_id,app.course_id,auth.uid(),course.current_version) returning id,certificate_number into cert_id,cert_number;
 end if;
 update public.certification_applications set status=p_decision,reviewed_by=auth.uid(),reviewed_at=now(),certificate_id=cert_id where id=app.id;
 insert into public.certification_application_reviews(application_id,reviewer_id,reviewer_role,decision,private_notes,evidence_request) values(app.id,auth.uid(),'admin',p_decision,left(coalesce(p_private_notes,''),3000),left(coalesce(p_evidence_request,''),2000));
 return jsonb_build_object('application_id',app.id,'decision',p_decision,'certificate_id',cert_id,'certificate_number',cert_number);
end $$;
revoke all on function public.admin_review_certification(uuid,text,text,text) from public,anon;
grant execute on function public.admin_review_certification(uuid,text,text,text) to authenticated;
create function public.admin_change_certificate(p_certificate_id uuid,p_decision text,p_reason text) returns jsonb language plpgsql security definer set search_path=public
as $$ declare prior public.certificates%rowtype; replacement_id uuid; replacement_number text; current_course_version integer; begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 if p_decision not in ('revoke','replace') or length(trim(coalesce(p_reason,'')))<5 then raise exception 'Choose revoke or replace and provide a reason'; end if;
 select * into prior from public.certificates where id=p_certificate_id for update;
 if prior.id is null or prior.revoked_at is not null then raise exception 'Certificate is not active'; end if;
 update public.certificates set revoked_at=now(),revocation_reason=left(p_reason,1000) where id=prior.id;
 if p_decision='replace' then
  select c.current_version into current_course_version from public.courses c where c.id=prior.course_id;
  insert into public.certificates(student_id,certification_id,course_id,issued_by,curriculum_version,certification_level_id)
  values(prior.student_id,prior.certification_id,prior.course_id,auth.uid(),coalesce(current_course_version,prior.curriculum_version),prior.certification_level_id) returning id,certificate_number into replacement_id,replacement_number;
  update public.certificates set replaced_by=replacement_id where id=prior.id;
 end if;
 return jsonb_build_object('decision',p_decision,'replacement_id',replacement_id,'replacement_number',replacement_number);
end $$;
revoke all on function public.admin_change_certificate(uuid,text,text) from public,anon;
grant execute on function public.admin_change_certificate(uuid,text,text) to authenticated;

create function public.write_audit_log() returns trigger language plpgsql security definer set search_path=public
as $$ declare target_id uuid; begin
  target_id:=coalesce((to_jsonb(new)->>'id')::uuid,(to_jsonb(new)->>'student_id')::uuid,(to_jsonb(old)->>'id')::uuid,(to_jsonb(old)->>'student_id')::uuid);
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),tg_op, tg_table_name,target_id,jsonb_build_object('old',case when tg_op='INSERT' then null else to_jsonb(old) end,'new',case when tg_op='DELETE' then null else to_jsonb(new) end));
  if tg_op='DELETE' then return old; else return new; end if;
end $$;
create function public.audit_student_profile_change() returns trigger language plpgsql security definer set search_path=public
as $$ begin
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'UPDATE','profiles',new.id,jsonb_build_object(
  'account_status_changed',old.account_status is distinct from new.account_status,
  'name_changed',old.full_name is distinct from new.full_name,
  'email_changed',old.email is distinct from new.email,
  'phone_changed',old.phone is distinct from new.phone,
  'location_changed',old.location is distinct from new.location));
 return new;
end $$;
create trigger audit_student_profile after update on public.profiles for each row when(old.role='student' and (old.account_status is distinct from new.account_status or old.full_name is distinct from new.full_name or old.email is distinct from new.email or old.phone is distinct from new.phone or old.location is distinct from new.location)) execute procedure public.audit_student_profile_change();
create trigger audit_enrolments after insert or update or delete on public.enrolments for each row execute procedure public.write_audit_log();
create trigger audit_certificates after insert or update on public.certificates for each row execute procedure public.write_audit_log();
create trigger audit_student_notes after insert on public.admin_student_notes for each row execute procedure public.write_audit_log();
create trigger audit_content_reviews after insert on public.content_reviews for each row execute procedure public.write_audit_log();
create trigger audit_certification_applications after insert or update on public.certification_applications for each row execute procedure public.write_audit_log();
create trigger audit_certification_reviews after insert on public.certification_application_reviews for each row execute procedure public.write_audit_log();
create trigger audit_group_members after insert or update or delete on public.group_members for each row execute procedure public.write_audit_log();
create trigger audit_competency_records after insert or update on public.competency_records for each row execute procedure public.write_audit_log();
create function public.audit_feedback_moderation() returns trigger language plpgsql security definer set search_path=public
as $$ begin
 insert into public.audit_logs(actor_id,action,entity_type,entity_id,details) values(auth.uid(),'MODERATE','feedback',new.id,jsonb_build_object('status_changed',old.status is distinct from new.status,'resolution_changed',old.resolution_status is distinct from new.resolution_status,'flagged',new.flagged));
 return new;
end $$;
create trigger audit_feedback_moderation after update on public.feedback for each row execute procedure public.audit_feedback_moderation();

-- An administrator-only report RPC avoids exposing notes or loading entire student histories into the client.
create function public.admin_student_report(p_student_id uuid) returns jsonb language plpgsql stable security definer set search_path=public
as $$ declare result jsonb; begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 select jsonb_build_object(
  'profile', (select to_jsonb(p) - 'accessibility_preferences' from public.profiles p where p.id=p_student_id and p.role='student'),
  'enrolments', coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'status',e.status,'progress',e.progress,'created_at',e.created_at,'course_title',c.title,'programme_title',pr.title) order by e.created_at desc) from public.enrolments e join public.courses c on c.id=e.course_id left join public.programmes pr on pr.id=c.programme_id where e.student_id=p_student_id),'[]'::jsonb),
  'assessments', coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'assessment_title',a.title,'score',s.score,'feedback',s.feedback,'submitted_at',s.submitted_at,'reviewed_at',s.reviewed_at) order by s.submitted_at desc) from public.assessment_submissions s join public.assessments a on a.id=s.assessment_id where s.student_id=p_student_id),'[]'::jsonb),
  'certificates', coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'certificate_number',c.certificate_number,'certification',cert.title,'issued_at',c.issued_at,'revoked_at',c.revoked_at,'revocation_reason',c.revocation_reason,'replaced_by',c.replaced_by) order by c.issued_at desc) from public.certificates c join public.certifications cert on cert.id=c.certification_id where c.student_id=p_student_id),'[]'::jsonb),
  'applications', coalesce((select jsonb_agg(jsonb_build_object('id',ca.id,'certification',cert.title,'course_id',ca.course_id,'status',ca.status,'created_at',ca.created_at) order by ca.created_at desc) from public.certification_applications ca join public.certifications cert on cert.id=ca.certification_id where ca.student_id=p_student_id),'[]'::jsonb),
  'competencies', coalesce((select jsonb_agg(jsonb_build_object('competency',co.title,'status',cr.status,'assessed_at',cr.assessed_at,'evidence',cr.evidence) order by cr.assessed_at desc) from public.competency_records cr join public.competencies co on co.id=cr.competency_id where cr.student_id=p_student_id),'[]'::jsonb)
 ) into result;
 return result;
end $$;
revoke all on function public.admin_student_report(uuid) from public, anon;
grant execute on function public.admin_student_report(uuid) to authenticated;

create function public.tutor_feedback_summary(p_course_id uuid) returns jsonb language plpgsql stable security definer set search_path=public
as $$ declare result jsonb; total_ratings bigint; average_rating numeric; distribution jsonb; begin
 if not exists(select 1 from public.courses c join public.profiles p on p.id=c.owner_id where c.id=p_course_id and c.owner_id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active') then raise exception 'Tutor access required'; end if;
 select count(*),round(avg(rating)::numeric,2) into total_ratings,average_rating from public.feedback where course_id=p_course_id and status='approved' and rating is not null;
 if total_ratings<5 then return jsonb_build_object('suppressed',true,'minimum',5); end if;
 select jsonb_object_agg(rating,n) into distribution from (select rating,count(*) n from public.feedback where course_id=p_course_id and status='approved' and rating is not null group by rating) d;
 result:=jsonb_build_object('suppressed',false,'count',total_ratings,'average',average_rating,'distribution',coalesce(distribution,'{}'::jsonb));
 return result;
end $$;
revoke all on function public.tutor_feedback_summary(uuid) from public, anon;
grant execute on function public.tutor_feedback_summary(uuid) to authenticated;

create function public.tutor_course_learning_summary(p_course_id uuid) returns jsonb language plpgsql stable security definer set search_path=public
as $$ declare total_students bigint; avg_progress numeric; completed bigint; reviewed bigint; pass_rate numeric; result jsonb; begin
 if not exists(select 1 from public.courses c join public.profiles p on p.id=c.owner_id where c.id=p_course_id and c.owner_id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active') then raise exception 'Tutor access required'; end if;
 select count(*) into total_students from public.enrolments where course_id=p_course_id and status in ('active','completed');
 if total_students<5 then return jsonb_build_object('suppressed',true,'minimum',5); end if;
 select round(avg(progress)::numeric,1),count(*) filter(where status='completed') into avg_progress,completed from public.enrolments where course_id=p_course_id and status in ('active','completed');
 select count(*) filter(where s.reviewed_at is not null),round(100.0*count(*) filter(where s.score>=a.pass_score)/nullif(count(*) filter(where s.score is not null),0),1) into reviewed,pass_rate from public.assessment_submissions s join public.assessments a on a.id=s.assessment_id where a.course_id=p_course_id and exists(select 1 from public.enrolments e where e.course_id=p_course_id and e.student_id=s.student_id and e.status in ('active','completed'));
 select jsonb_build_object('suppressed',false,'student_count',total_students,'average_progress',avg_progress,'completed_count',completed,'completion_rate',round(100.0*completed/nullif(total_students,0),1),'assessments_reviewed',reviewed,'assessment_pass_rate',pass_rate) into result;
 return coalesce(result,jsonb_build_object('suppressed',true,'minimum',5));
end $$;
revoke all on function public.tutor_course_learning_summary(uuid) from public, anon;
grant execute on function public.tutor_course_learning_summary(uuid) to authenticated;

create function public.verify_certificate(p_certificate_number text) returns jsonb language sql stable security definer set search_path=public
as $$ select jsonb_build_object('certificate_number',c.certificate_number,'credential',cert.title,'course',coalesce(course.title,'Course credential'),'issued_at',c.issued_at,'valid',c.revoked_at is null)
 from public.certificates c join public.certifications cert on cert.id=c.certification_id left join public.courses course on course.id=c.course_id
 where c.certificate_number=p_certificate_number $$;
revoke all on function public.verify_certificate(text) from public;
grant execute on function public.verify_certificate(text) to anon,authenticated;

alter table public.learning_groups enable row level security;
alter table public.group_members enable row level security;
alter table public.admin_student_notes enable row level security;
alter table public.audit_logs enable row level security;
alter table public.certification_levels enable row level security;
alter table public.competencies enable row level security;
alter table public.competency_records enable row level security;
alter table public.certification_applications enable row level security;
alter table public.certification_application_reviews enable row level security;
alter table public.course_versions enable row level security;
alter table public.content_reviews enable row level security;

create policy "Admin manage learning groups" on public.learning_groups for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Students see own group membership" on public.group_members for select to authenticated using(student_id=auth.uid() and public.is_active_user() or public.is_admin());
create policy "Admins manage group membership" on public.group_members for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Private notes are administrator only" on public.admin_student_notes for all to authenticated using(public.is_admin()) with check(public.is_admin() and author_id=auth.uid());
create policy "Audit history is administrator only" on public.audit_logs for select to authenticated using(public.is_admin());
create policy "Certification levels readable" on public.certification_levels for select using(true);
create policy "Admins manage certification levels" on public.certification_levels for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Competencies readable" on public.competencies for select using(true);
create policy "Admins manage competencies" on public.competencies for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Students see own competency records" on public.competency_records for select to authenticated using(student_id=auth.uid() and public.is_active_user() or public.is_admin());
create policy "Admins manage competency records" on public.competency_records for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Certification applications visible to student or admin" on public.certification_applications for select to authenticated using(student_id=auth.uid() and public.is_active_user() or public.is_admin());
create policy "Tutors recommend certifications" on public.certification_applications for insert to authenticated with check(recommended_by=auth.uid() and public.current_role()='tutor' and public.is_active_user() and exists(select 1 from public.profiles tp where tp.id=auth.uid() and tp.tutor_approved) and exists(select 1 from public.courses c join public.enrolments e on e.course_id=c.id where c.id=certification_applications.course_id and c.owner_id=auth.uid() and e.student_id=certification_applications.student_id and e.status in ('active','completed')));
create policy "Admins review certification applications" on public.certification_applications for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Reviewers manage own certification review notes" on public.certification_application_reviews for all to authenticated using(public.is_admin() or (reviewer_id=auth.uid() and public.current_role()='tutor' and exists(select 1 from public.certification_applications ca join public.courses c on c.id=ca.course_id where ca.id=application_id and c.owner_id=auth.uid()))) with check(public.is_admin() or (reviewer_id=auth.uid() and public.current_role()='tutor' and exists(select 1 from public.certification_applications ca join public.courses c on c.id=ca.course_id where ca.id=application_id and c.owner_id=auth.uid())));
create policy "Admins review all certification applications" on public.certification_application_reviews for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Course versions readable to members" on public.course_versions for select to authenticated using(public.is_admin() or exists(select 1 from public.courses c where c.id=course_id and (c.owner_id=auth.uid() or c.status='published')));
create policy "Admins manage course versions" on public.course_versions for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Admins manage content reviews" on public.content_reviews for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "Submitters view own review decisions" on public.content_reviews for select to authenticated using(submitted_by=auth.uid());

-- Tutors never receive individual student feedback. Students see only their own submissions; admins moderate all.
drop policy if exists "Approved feedback readable; insert allowed" on public.feedback;
drop policy if exists "Students submit feedback" on public.feedback;
create policy "Feedback private to author or admin" on public.feedback for select to authenticated using(student_id=auth.uid() and public.is_active_user() or public.is_admin());
create policy "Active students submit feedback" on public.feedback for insert to authenticated with check((student_id=auth.uid() and public.current_role()='student' and public.is_active_user()) or (student_id is null and auth.uid() is null));
create policy "Admins moderate feedback records" on public.feedback for update to authenticated using(public.is_admin()) with check(public.is_admin());

-- Disable self-service data access after suspension, deactivation, or before student approval.
drop policy if exists "Profile read self or admin" on public.profiles;
create policy "Profile read own status or admin" on public.profiles for select to authenticated using(id=auth.uid() or public.is_admin());
drop policy if exists "Profile update self or admin" on public.profiles;
create policy "Profile update active self or admin" on public.profiles for update to authenticated using((id=auth.uid() and public.is_active_user()) or public.is_admin()) with check((id=auth.uid() and public.is_active_user()) or public.is_admin());
drop policy if exists "Published courses readable" on public.courses;
create policy "Published open courses or enrolled course readable" on public.courses for select using((status='published' and enrolment_open) or exists(select 1 from public.enrolments e where e.course_id=courses.id and e.student_id=auth.uid() and e.status in ('active','completed') and public.is_active_user()) or (owner_id=auth.uid() and public.is_active_user()) or public.is_admin());
drop policy if exists "Students see own enrolments" on public.enrolments;
create policy "Enrolments visible to students and admins" on public.enrolments for select to authenticated using((student_id=auth.uid() and public.is_active_user()) or public.is_admin());
drop policy if exists "Students enrol self" on public.enrolments;
create policy "Active students request enrolment" on public.enrolments for insert to authenticated with check(student_id=auth.uid() and public.current_role()='student' and public.is_active_user() and status='pending' and exists(select 1 from public.courses c where c.id=course_id and c.status='published' and c.enrolment_open));
drop policy if exists "Admins manage enrolments" on public.enrolments;
create policy "Admins manage enrolments" on public.enrolments for all to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists "Students manage own progress" on public.lesson_progress;
create policy "Active students manage own enrolled progress" on public.lesson_progress for all to authenticated using((student_id=auth.uid() and public.is_active_user() and exists(select 1 from public.lessons l join public.modules m on m.id=l.module_id join public.enrolments e on e.course_id=m.course_id where l.id=lesson_progress.lesson_id and e.student_id=auth.uid() and e.status in ('active','completed'))) or public.is_admin()) with check((student_id=auth.uid() and public.is_active_user() and exists(select 1 from public.lessons l join public.modules m on m.id=l.module_id join public.enrolments e on e.course_id=m.course_id where l.id=lesson_progress.lesson_id and e.student_id=auth.uid() and e.status in ('active','completed'))) or public.is_admin());
drop policy if exists "Certificates owner or admin" on public.certificates;
create policy "Active certificate owner or admin" on public.certificates for select to authenticated using(student_id=auth.uid() and public.is_active_user() or public.is_admin());
create policy "Admins update certificates" on public.certificates for update to authenticated using(public.is_admin()) with check(public.is_admin());

drop policy if exists "Tutors manage own courses" on public.courses;
create policy "Approved active tutors manage own courses" on public.courses for all to authenticated using((owner_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active')) or public.is_admin()) with check((owner_id=auth.uid() and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active')) or public.is_admin());
drop policy if exists "Course owners manage modules" on public.modules;
create policy "Active course owners manage modules" on public.modules for all to authenticated using(exists(select 1 from public.courses c where c.id=course_id and ((c.owner_id=auth.uid() and public.is_active_user()) or public.is_admin()))) with check(exists(select 1 from public.courses c where c.id=course_id and ((c.owner_id=auth.uid() and public.is_active_user()) or public.is_admin())));
drop policy if exists "Course owners manage lessons" on public.lessons;
create policy "Active course owners manage lessons" on public.lessons for all to authenticated using(exists(select 1 from public.modules m join public.courses c on c.id=m.course_id where m.id=module_id and ((c.owner_id=auth.uid() and public.is_active_user()) or public.is_admin()))) with check(exists(select 1 from public.modules m join public.courses c on c.id=m.course_id where m.id=module_id and ((c.owner_id=auth.uid() and public.is_active_user()) or public.is_admin())));
drop policy if exists "Course owners manage assessments" on public.assessments;
create policy "Active course owners manage assessments" on public.assessments for all to authenticated using(exists(select 1 from public.courses c where c.id=course_id and ((c.owner_id=auth.uid() and public.is_active_user()) or public.is_admin()))) with check(exists(select 1 from public.courses c where c.id=course_id and ((c.owner_id=auth.uid() and public.is_active_user()) or public.is_admin())));
drop policy if exists "Professional manages own services" on public.services;
create policy "Active professionals manage services" on public.services for all to authenticated using(exists(select 1 from public.professionals p where p.id=professional_id and ((p.profile_id=auth.uid() and public.is_active_user()) or public.is_admin()))) with check(exists(select 1 from public.professionals p where p.id=professional_id and ((p.profile_id=auth.uid() and public.is_active_user()) or public.is_admin())));
drop policy if exists "Professionals edit own profile" on public.professionals;
create policy "Active professionals edit own profile" on public.professionals for all to authenticated using((profile_id=auth.uid() and public.is_active_user()) or public.is_admin()) with check((profile_id=auth.uid() and public.is_active_user()) or public.is_admin());

drop policy if exists "Submissions visible to student or course tutor" on public.assessment_submissions;
create policy "Submissions visible to students and admins" on public.assessment_submissions for select to authenticated using((student_id=auth.uid() and public.is_active_user()) or public.is_admin());
drop policy if exists "Students submit assessments" on public.assessment_submissions;
create policy "Active enrolled students submit assessments" on public.assessment_submissions for insert to authenticated with check(student_id=auth.uid() and public.current_role()='student' and public.is_active_user() and exists(select 1 from public.assessments a join public.enrolments e on e.course_id=a.course_id where a.id=assessment_submissions.assessment_id and e.student_id=auth.uid() and e.status in ('active','completed')));
drop policy if exists "Tutors review submissions" on public.assessment_submissions;
create policy "Admins update submissions" on public.assessment_submissions for update to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists "Bookings visible to involved parties" on public.bookings;
create policy "Bookings visible to active parties" on public.bookings for select to authenticated using((customer_id=auth.uid() and public.is_active_user()) or exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid() and public.is_active_user()) or public.is_admin());
drop policy if exists "Customers request bookings" on public.bookings;
create policy "Active customers request bookings" on public.bookings for insert to authenticated with check(customer_id=auth.uid() and public.current_role()='customer' and public.is_active_user());
drop policy if exists "Booking parties update bookings" on public.bookings;
create policy "Active booking parties update bookings" on public.bookings for update to authenticated using((customer_id=auth.uid() and public.is_active_user()) or exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid() and public.is_active_user()) or public.is_admin()) with check((customer_id=auth.uid() and public.is_active_user()) or exists(select 1 from public.professionals p where p.id=professional_id and p.profile_id=auth.uid() and public.is_active_user()) or public.is_admin());
drop policy if exists "Message participants read" on public.messages;
create policy "Active message participants read" on public.messages for select to authenticated using(((sender_id=auth.uid() or recipient_id=auth.uid()) and public.is_active_user()) or public.is_admin());
drop policy if exists "Message participants send" on public.messages;
create policy "Active message participants send" on public.messages for insert to authenticated with check(sender_id=auth.uid() and public.is_active_user() and exists(select 1 from public.bookings b join public.professionals p on p.id=b.professional_id where b.id=booking_id and ((b.customer_id=auth.uid() and p.profile_id=recipient_id) or (p.profile_id=auth.uid() and b.customer_id=recipient_id))));
drop policy if exists "Recipients mark read" on public.messages;
create policy "Active recipients mark read" on public.messages for update to authenticated using((recipient_id=auth.uid() and public.is_active_user()) or public.is_admin()) with check((recipient_id=auth.uid() and public.is_active_user()) or public.is_admin());
drop policy if exists "Users access own submissions" on storage.objects;
create policy "Active users access own submissions" on storage.objects for select to authenticated using(bucket_id='student-submissions' and (((storage.foldername(name))[1]=auth.uid()::text and public.is_active_user()) or public.is_admin()));
drop policy if exists "Authenticated users upload submissions" on storage.objects;
create policy "Active students upload submissions" on storage.objects for insert to authenticated with check(bucket_id='student-submissions' and (storage.foldername(name))[1]=auth.uid()::text and public.current_role()='student' and public.is_active_user());

-- Administrative account changes are written to the audit trail by the profile trigger above.
