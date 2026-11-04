-- Tutor-facing records use opaque aliases and scoped RPCs. Direct learner identity reads stay unavailable.
create table public.tutor_learner_aliases(
  course_id uuid not null references public.courses(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  learner_alias text not null,
  created_at timestamptz not null default now(),
  primary key(course_id,student_id),
  unique(course_id,learner_alias)
);
alter table public.tutor_learner_aliases enable row level security;
create policy "Admins inspect tutor alias mapping" on public.tutor_learner_aliases for select to authenticated using(public.is_admin());
revoke all on public.tutor_learner_aliases from anon,authenticated;
grant select on public.tutor_learner_aliases to authenticated;

create policy "Approved tutors submit assessment reviews" on public.content_reviews for insert to authenticated with check(
 submitted_by=auth.uid() and entity_type='assessment' and decision='submitted' and exists(
  select 1 from public.assessments a join public.courses c on c.id=a.course_id join public.profiles p on p.id=auth.uid()
  where a.id=entity_id and a.status='pending' and c.owner_id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active'
 )
);

drop policy if exists "Lessons follow course access" on public.lessons;
create policy "Published lessons visible to enrolled learners" on public.lessons for select to authenticated using(
 public.is_admin() or exists(select 1 from public.modules m join public.courses c on c.id=m.course_id where m.id=module_id and c.owner_id=auth.uid()) or
 (status='published' and exists(select 1 from public.modules m join public.courses c on c.id=m.course_id join public.enrolments e on e.course_id=c.id where m.id=module_id and c.status='published' and e.student_id=auth.uid() and e.status in ('active','completed') and public.current_role()='student' and public.is_active_user()))
);
drop policy if exists "Assessments visible to learners and tutors" on public.assessments;
create policy "Published assessments visible to enrolled learners" on public.assessments for select to authenticated using(
 public.is_admin() or exists(select 1 from public.courses c where c.id=course_id and c.owner_id=auth.uid()) or
 (status='published' and exists(select 1 from public.courses c join public.enrolments e on e.course_id=c.id where c.id=course_id and c.status='published' and e.student_id=auth.uid() and e.status in ('active','completed') and public.current_role()='student' and public.is_active_user()))
);

drop policy if exists "Submissions visible to learner, assigned tutor, or admin" on public.assessment_submissions;
create policy "Submissions visible to learner or admin" on public.assessment_submissions for select to authenticated
  using((student_id=auth.uid() and public.is_active_user()) or public.is_admin());

create or replace function public._tutor_alias(p_course_id uuid,p_student_id uuid) returns text
language plpgsql security definer set search_path=public as $$
declare found_alias text; candidate text;
begin
  select learner_alias into found_alias from public.tutor_learner_aliases where course_id=p_course_id and student_id=p_student_id;
  if found_alias is not null then return found_alias; end if;
  loop
    candidate:='Learner-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    begin
      insert into public.tutor_learner_aliases(course_id,student_id,learner_alias) values(p_course_id,p_student_id,candidate) on conflict(course_id,student_id) do nothing;
    exception when unique_violation then
      continue;
    end;
    select learner_alias into found_alias from public.tutor_learner_aliases where course_id=p_course_id and student_id=p_student_id;
    if found_alias is not null then return found_alias; end if;
  end loop;
end $$;
revoke all on function public._tutor_alias(uuid,uuid) from public,anon,authenticated;

create function public.tutor_assessment_queue(p_course_id uuid default null)
returns table(submission_id uuid,assessment_id uuid,assessment_title text,course_id uuid,course_title text,learner_alias text,answer text,has_file boolean,score numeric,pass_score numeric,max_score numeric,feedback text,submitted_at timestamptz,reviewed_at timestamptz,criteria jsonb)
language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from public.profiles where id=auth.uid() and role='tutor' and tutor_approved and account_status='active') then raise exception 'Approved tutor access required'; end if;
  if p_course_id is not null and not exists(select 1 from public.courses where id=p_course_id and owner_id=auth.uid()) then raise exception 'Course is not assigned to this tutor'; end if;
  return query select s.id,a.id,a.title,c.id,c.title,public._tutor_alias(c.id,s.student_id),s.answer,(s.file_path is not null),s.score,a.pass_score,a.max_score,s.feedback,s.submitted_at,s.reviewed_at,a.criteria
    from public.assessment_submissions s join public.assessments a on a.id=s.assessment_id join public.courses c on c.id=a.course_id
    where c.owner_id=auth.uid() and (p_course_id is null or c.id=p_course_id)
    order by (s.reviewed_at is not null),s.submitted_at desc limit 300;
end $$;
revoke all on function public.tutor_assessment_queue(uuid) from public,anon;
grant execute on function public.tutor_assessment_queue(uuid) to authenticated;

create function public.tutor_course_approval_timeline(p_course_id uuid)
returns table(review_id uuid,entity_id uuid,entity_type text,decision text,reason text,submitted_at timestamptz,reviewed_at timestamptz,version integer)
language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.courses where id=p_course_id and owner_id=auth.uid() and exists(select 1 from public.profiles where id=auth.uid() and role='tutor' and tutor_approved and account_status='active')) then raise exception 'Course is not assigned to this tutor'; end if;
 return query select cr.id,cr.entity_id,cr.entity_type,cr.decision,cr.reason,cr.created_at,cr.reviewed_at,cr.version from public.content_reviews cr
  where (cr.entity_type='course' and cr.entity_id=p_course_id) or (cr.entity_type='lesson' and cr.entity_id in(select l.id from public.lessons l join public.modules m on m.id=l.module_id where m.course_id=p_course_id)) or (cr.entity_type='assessment' and cr.entity_id in(select a.id from public.assessments a where a.course_id=p_course_id))
  order by cr.created_at desc;
end $$;
revoke all on function public.tutor_course_approval_timeline(uuid) from public,anon;
grant execute on function public.tutor_course_approval_timeline(uuid) to authenticated;

create function public.tutor_certification_candidates(p_course_id uuid)
returns table(learner_alias text,course_id uuid,progress numeric,minimum_completion numeric,assessment_requirements_met boolean,competency_requirements_met boolean,latest_application_status text)
language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.courses c join public.profiles p on p.id=c.owner_id where c.id=p_course_id and c.owner_id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active') then raise exception 'Course is not assigned to this tutor'; end if;
 return query select public._tutor_alias(e.course_id,e.student_id),e.course_id,e.progress,c.minimum_completion,
   not exists(select 1 from public.assessments a where a.course_id=c.id and a.required and a.status='published' and not exists(select 1 from public.assessment_submissions s where s.assessment_id=a.id and s.student_id=e.student_id and s.reviewed_at is not null and s.score>=a.pass_score)),
   not exists(select 1 from unnest(c.required_competencies) req(id) where not exists(select 1 from public.competency_records cr where cr.student_id=e.student_id and cr.competency_id=req.id and cr.status in ('competent','mastered'))),
   (select ca.status from public.certification_applications ca where ca.student_id=e.student_id and ca.course_id=c.id order by ca.created_at desc limit 1)
  from public.enrolments e join public.courses c on c.id=e.course_id where c.id=p_course_id and e.status in ('active','completed') order by e.progress desc;
end $$;
revoke all on function public.tutor_certification_candidates(uuid) from public,anon;
grant execute on function public.tutor_certification_candidates(uuid) to authenticated;

create function public.tutor_recommend_certification(p_course_id uuid,p_learner_alias text,p_certification_id uuid,p_notes text default '') returns boolean
language plpgsql security definer set search_path=public as $$
declare student_key uuid; course_row public.courses%rowtype; application_key uuid;
begin
 if not exists(select 1 from public.courses c join public.profiles p on p.id=c.owner_id where c.id=p_course_id and c.owner_id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active') then raise exception 'Course is not assigned to this tutor'; end if;
 select student_id into student_key from public.tutor_learner_aliases where course_id=p_course_id and learner_alias=p_learner_alias;
 if student_key is null then raise exception 'Learner alias is not in this course'; end if;
 select * into course_row from public.courses where id=p_course_id;
 if not exists(select 1 from public.enrolments e where e.student_id=student_key and e.course_id=p_course_id and e.progress>=course_row.minimum_completion and e.status in ('active','completed')) then raise exception 'Completion requirements are not met'; end if;
 if exists(select 1 from public.assessments a where a.course_id=p_course_id and a.required and a.status='published' and not exists(select 1 from public.assessment_submissions s where s.assessment_id=a.id and s.student_id=student_key and s.reviewed_at is not null and s.score>=a.pass_score)) then raise exception 'Required assessments are outstanding'; end if;
 if exists(select 1 from unnest(course_row.required_competencies) req(id) where not exists(select 1 from public.competency_records cr where cr.student_id=student_key and cr.competency_id=req.id and cr.status in ('competent','mastered'))) then raise exception 'Required competencies are outstanding'; end if;
 if not exists(select 1 from public.certifications cr where cr.id=p_certification_id and (cr.course_id is null or cr.course_id=p_course_id)) then raise exception 'Certification does not match this course'; end if;
 if exists(select 1 from public.certification_applications ca where ca.student_id=student_key and ca.course_id=p_course_id and ca.certification_id=p_certification_id and ca.status in ('pending_tutor','pending_admin','approved')) then raise exception 'A certification recommendation already exists'; end if;
 insert into public.certification_applications(student_id,certification_id,course_id,recommended_by,status) values(student_key,p_certification_id,p_course_id,auth.uid(),'pending_admin') returning id into application_key;
 insert into public.certification_application_reviews(application_id,reviewer_id,reviewer_role,decision,private_notes) values(application_key,auth.uid(),'tutor','recommended',left(coalesce(p_notes,''),3000));
 return true;
end $$;
revoke all on function public.tutor_recommend_certification(uuid,text,uuid,text) from public,anon;
grant execute on function public.tutor_recommend_certification(uuid,text,uuid,text) to authenticated;

-- Consultations can only be opened by an enrolled student. Tutor-visible data is exposed through pseudonymous RPCs.
create table public.course_consultations(
 id uuid primary key default gen_random_uuid(),student_id uuid not null references public.profiles(id) on delete cascade,
 tutor_id uuid not null references public.profiles(id),course_id uuid not null references public.courses(id) on delete cascade,
 module_id uuid references public.modules(id) on delete set null,lesson_id uuid references public.lessons(id) on delete set null,
 subject text not null check(length(subject) between 2 and 160),status text not null default 'open' check(status in ('open','closed','reported')),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table public.course_consultation_messages(
 id uuid primary key default gen_random_uuid(),consultation_id uuid not null references public.course_consultations(id) on delete cascade,
 sender_id uuid not null references public.profiles(id) on delete cascade,body text not null check(length(body) between 1 and 3000),
 created_at timestamptz not null default now(),read_at timestamptz,reported_at timestamptz
);
alter table public.course_consultations enable row level security;
alter table public.course_consultation_messages enable row level security;
create policy "Consultation participant or admin read" on public.course_consultations for select to authenticated using(student_id=auth.uid() or tutor_id=auth.uid() or public.is_admin());
create policy "Consultation message participant or admin read" on public.course_consultation_messages for select to authenticated using(public.is_admin() or exists(select 1 from public.course_consultations cc where cc.id=consultation_id and (cc.student_id=auth.uid() or cc.tutor_id=auth.uid())));
revoke all on public.course_consultations,public.course_consultation_messages from anon,authenticated;

create function public.student_start_course_consultation(p_course_id uuid,p_module_id uuid,p_lesson_id uuid,p_subject text,p_body text) returns uuid
language plpgsql security definer set search_path=public as $$
declare tutor_key uuid; consultation_key uuid;
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and role='student' and account_status='active') then raise exception 'Active student access required'; end if;
 if length(trim(coalesce(p_subject,'')))<2 or length(p_subject)>160 then raise exception 'Enter a short consultation subject'; end if;
 if lower(p_subject) ~* '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' or lower(p_subject) ~* '(https?://|www\.|[a-z0-9-]+\.(com|net|org|io|co\.ug|ug)(/|\b))' or lower(p_subject) ~* '(^|[[:space:]])@[a-z0-9_.]{2,}' or lower(p_subject) ~* '(\+?[0-9][0-9 ()-]{7,}[0-9])' or lower(p_subject) ~* '(whatsapp|telegram|signal|instagram|facebook|snapchat|call me|text me|email me|my number|my contact|contact me)' then raise exception 'The subject appears to include contact details. Please keep conversations on GlowBiz.'; end if;
 if exists(select 1 from public.enrolments where student_id=auth.uid() and course_id=p_course_id and status not in ('active','completed')) or not exists(select 1 from public.enrolments where student_id=auth.uid() and course_id=p_course_id and status in ('active','completed')) then raise exception 'Active course enrolment required'; end if;
 select owner_id into tutor_key from public.courses where id=p_course_id and status='published';if tutor_key is null then raise exception 'Course consultation is unavailable'; end if;
 if p_module_id is not null and not exists(select 1 from public.modules where id=p_module_id and course_id=p_course_id) then raise exception 'Module does not belong to this course'; end if;
 if p_lesson_id is not null and not exists(select 1 from public.lessons l join public.modules m on m.id=l.module_id where l.id=p_lesson_id and m.course_id=p_course_id and (p_module_id is null or m.id=p_module_id)) then raise exception 'Lesson does not belong to this course'; end if;
 insert into public.course_consultations(student_id,tutor_id,course_id,module_id,lesson_id,subject) values(auth.uid(),tutor_key,p_course_id,p_module_id,p_lesson_id,p_subject) returning id into consultation_key;
 perform public._send_course_consultation_message(consultation_key,p_body);
 return consultation_key;
end $$;

create function public._send_course_consultation_message(p_consultation_id uuid,p_body text) returns uuid
language plpgsql security definer set search_path=public as $$
declare consultation_row public.course_consultations%rowtype; message_key uuid; lower_body text:=lower(coalesce(p_body,''));
begin
 select * into consultation_row from public.course_consultations where id=p_consultation_id;
 if consultation_row.id is null or auth.uid() not in (consultation_row.student_id,consultation_row.tutor_id) then raise exception 'Consultation access required'; end if;
 if not exists(select 1 from public.profiles p where p.id=auth.uid() and p.account_status='active' and ((auth.uid()=consultation_row.student_id and p.role='student') or (auth.uid()=consultation_row.tutor_id and p.role='tutor' and p.tutor_approved))) then raise exception 'Active consultation account required'; end if;
 if consultation_row.status<>'open' then raise exception 'This consultation is closed'; end if;
 if length(trim(coalesce(p_body,'')))<1 or length(p_body)>3000 then raise exception 'Message must be between 1 and 3000 characters'; end if;
 if lower_body ~* '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' or lower_body ~* '(https?://|www\.|[a-z0-9-]+\.(com|net|org|io|co\.ug|ug)(/|\b))' or lower_body ~* '(^|[[:space:]])@[a-z0-9_.]{2,}' or lower_body ~* '(\+?[0-9][0-9 ()-]{7,}[0-9])' or lower_body ~* '(whatsapp|telegram|signal|instagram|facebook|snapchat|call me|text me|email me|my number|my contact|contact me)' then raise exception 'This message appears to include contact details or an off-platform contact request. Please keep conversations on GlowBiz.'; end if;
 insert into public.course_consultation_messages(consultation_id,sender_id,body) values(p_consultation_id,auth.uid(),trim(p_body)) returning id into message_key;
 update public.course_consultations set updated_at=now() where id=p_consultation_id;
 return message_key;
end $$;
create function public.send_course_consultation_message(p_consultation_id uuid,p_body text) returns uuid language plpgsql security definer set search_path=public as $$ begin return public._send_course_consultation_message(p_consultation_id,p_body); end $$;
revoke all on function public._send_course_consultation_message(uuid,text) from public,anon,authenticated;
revoke all on function public.send_course_consultation_message(uuid,text) from public,anon;
revoke all on function public.student_start_course_consultation(uuid,uuid,uuid,text,text) from public,anon;
grant execute on function public.send_course_consultation_message(uuid,text) to authenticated;
grant execute on function public.student_start_course_consultation(uuid,uuid,uuid,text,text) to authenticated;

create function public.tutor_consultation_inbox() returns table(consultation_id uuid,course_title text,subject text,learner_alias text,status text,updated_at timestamptz,unread_count bigint,last_message text)
language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and role='tutor' and tutor_approved and account_status='active') then raise exception 'Approved tutor access required'; end if;
 return query select cc.id,c.title,cc.subject,public._tutor_alias(cc.course_id,cc.student_id),cc.status,cc.updated_at,
  (select count(*) from public.course_consultation_messages cm where cm.consultation_id=cc.id and cm.sender_id<>auth.uid() and cm.read_at is null),
  (select cm.body from public.course_consultation_messages cm where cm.consultation_id=cc.id order by cm.created_at desc limit 1)
 from public.course_consultations cc join public.courses c on c.id=cc.course_id where cc.tutor_id=auth.uid() and c.owner_id=auth.uid() order by cc.updated_at desc;
end $$;
create function public.consultation_messages(p_consultation_id uuid) returns table(message_id uuid,sender_label text,body text,created_at timestamptz,is_mine boolean)
language plpgsql security definer set search_path=public as $$
declare context public.course_consultations%rowtype;
begin
 select * into context from public.course_consultations where id=p_consultation_id;
 if context.id is null or auth.uid() not in (context.student_id,context.tutor_id) and not public.is_admin() then raise exception 'Consultation access required'; end if;
 if not public.is_admin() and not exists(select 1 from public.profiles p where p.id=auth.uid() and p.account_status='active' and ((auth.uid()=context.student_id and p.role='student') or (auth.uid()=context.tutor_id and p.role='tutor' and p.tutor_approved))) then raise exception 'Active consultation account required'; end if;
 if auth.uid()=context.tutor_id and not public.is_admin() and not exists(select 1 from public.courses where id=context.course_id and owner_id=auth.uid()) then raise exception 'Course is not assigned to this tutor'; end if;
 update public.course_consultation_messages set read_at=now() where consultation_id=p_consultation_id and sender_id<>auth.uid() and read_at is null;
 return query select cm.id,case when cm.sender_id=auth.uid() then 'You' when auth.uid()=context.tutor_id then public._tutor_alias(context.course_id,context.student_id) else 'Tutor' end,cm.body,cm.created_at,cm.sender_id=auth.uid() from public.course_consultation_messages cm where cm.consultation_id=p_consultation_id order by cm.created_at;
end $$;
revoke all on function public.tutor_consultation_inbox() from public,anon;
revoke all on function public.consultation_messages(uuid) from public,anon;
grant execute on function public.tutor_consultation_inbox() to authenticated;
grant execute on function public.consultation_messages(uuid) to authenticated;

create function public.consultation_header(p_consultation_id uuid) returns table(subject text,status text)
language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.course_consultations cc where cc.id=p_consultation_id and (cc.student_id=auth.uid() or (cc.tutor_id=auth.uid() and exists(select 1 from public.courses c where c.id=cc.course_id and c.owner_id=auth.uid())) or public.is_admin())) then raise exception 'Consultation access required'; end if;
 if not public.is_admin() and not exists(select 1 from public.course_consultations cc join public.profiles p on p.id=auth.uid() where cc.id=p_consultation_id and p.account_status='active' and ((p.id=cc.student_id and p.role='student') or (p.id=cc.tutor_id and p.role='tutor' and p.tutor_approved))) then raise exception 'Active consultation account required'; end if;
 return query select cc.subject,cc.status from public.course_consultations cc where cc.id=p_consultation_id;
end $$;
revoke all on function public.consultation_header(uuid) from public,anon;
grant execute on function public.consultation_header(uuid) to authenticated;

create function public.tutor_report_consultation(p_consultation_id uuid) returns boolean language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.course_consultations cc join public.courses c on c.id=cc.course_id join public.profiles p on p.id=auth.uid() where cc.id=p_consultation_id and cc.tutor_id=auth.uid() and c.owner_id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active') then raise exception 'Consultation not assigned to this tutor'; end if;
 update public.course_consultations set status='reported',updated_at=now() where id=p_consultation_id;return true;
end $$;
revoke all on function public.tutor_report_consultation(uuid) from public,anon;
grant execute on function public.tutor_report_consultation(uuid) to authenticated;

create index course_consultations_tutor_updated_idx on public.course_consultations(tutor_id,updated_at desc);
create index consultation_messages_conversation_idx on public.course_consultation_messages(consultation_id,created_at);

create function public.admin_review_assessment_content(p_review_id uuid,p_decision text,p_reason text default '') returns boolean
language plpgsql security definer set search_path=public as $$
declare review_row public.content_reviews%rowtype;
begin
 if not public.is_admin() then raise exception 'Administrator access required'; end if;
 if p_decision not in ('approved','changes_requested','rejected') or length(coalesce(p_reason,''))>3000 then raise exception 'Invalid review decision'; end if;
 select * into review_row from public.content_reviews where id=p_review_id and entity_type='assessment' and decision in ('submitted','under_review');
 if review_row.id is null then raise exception 'Assessment review is no longer pending'; end if;
 update public.assessments set status=case when p_decision='approved' then 'published'::public.review_status else 'draft'::public.review_status end where id=review_row.entity_id;
 update public.content_reviews set decision=p_decision,reviewer_id=auth.uid(),reason=coalesce(p_reason,''),reviewed_at=now() where id=p_review_id;
 return true;
end $$;
revoke all on function public.admin_review_assessment_content(uuid,text,text) from public,anon;
grant execute on function public.admin_review_assessment_content(uuid,text,text) to authenticated;

create function public.audit_tutor_grade() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.score is distinct from old.score or new.feedback is distinct from old.feedback or new.reviewed_at is distinct from old.reviewed_at then
  insert into public.audit_logs(actor_id,action,entity_type,entity_id,details)
  values(auth.uid(),'GRADE_ASSESSMENT_SUBMISSION','assessment_submissions',new.id,jsonb_build_object('previous_score',old.score,'score',new.score,'feedback_changed',new.feedback is distinct from old.feedback,'reviewed_at',new.reviewed_at));
 end if;
 return new;
end $$;
create trigger audit_tutor_grade_update after update of score,feedback,reviewed_at on public.assessment_submissions for each row execute function public.audit_tutor_grade();

drop policy if exists "Course tutors read learner submissions" on storage.objects;

create function public.student_consultation_inbox() returns table(consultation_id uuid,course_title text,subject text,status text,updated_at timestamptz,unread_count bigint,last_message text)
language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and role='student' and account_status='active') then raise exception 'Active student access required'; end if;
 return query select cc.id,c.title,cc.subject,cc.status,cc.updated_at,
  (select count(*) from public.course_consultation_messages cm where cm.consultation_id=cc.id and cm.sender_id<>auth.uid() and cm.read_at is null),
  (select cm.body from public.course_consultation_messages cm where cm.consultation_id=cc.id order by cm.created_at desc limit 1)
 from public.course_consultations cc join public.courses c on c.id=cc.course_id where cc.student_id=auth.uid() order by cc.updated_at desc;
end $$;
revoke all on function public.student_consultation_inbox() from public,anon;
grant execute on function public.student_consultation_inbox() to authenticated;
