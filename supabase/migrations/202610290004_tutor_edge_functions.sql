-- Give tutors privacy-safe course analytics at a selected enrollment period.
create function public.tutor_course_analytics(p_course_id uuid,p_from timestamptz default null,p_to timestamptz default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb; learner_count bigint; average_progress numeric; completion_count bigint; attempt_count bigint; reviewed_count bigint; passed_count bigint; average_score numeric; activity_count bigint; module_rows jsonb; learner_rows jsonb;
begin
 if not exists(select 1 from public.courses c join public.profiles p on p.id=c.owner_id where c.id=p_course_id and c.owner_id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active') then raise exception 'Course is not assigned to this tutor'; end if;
 if p_from is not null and p_to is not null and p_from>p_to then raise exception 'Invalid analytics date range'; end if;
 select count(*),round(avg(e.progress)::numeric,1),count(*) filter(where e.status='completed') into learner_count,average_progress,completion_count
 from public.enrolments e where e.course_id=p_course_id and e.status in ('active','completed') and (p_from is null or e.created_at>=p_from) and (p_to is null or e.created_at<p_to);
 select count(*),count(*) filter(where s.reviewed_at is not null),count(*) filter(where s.reviewed_at is not null and s.score>=a.pass_score),round(avg(s.score) filter(where s.reviewed_at is not null)::numeric,1)
 into attempt_count,reviewed_count,passed_count,average_score
 from public.assessment_submissions s join public.assessments a on a.id=s.assessment_id join public.enrolments e on e.student_id=s.student_id and e.course_id=a.course_id and e.status in ('active','completed')
 where a.course_id=p_course_id and (p_from is null or s.submitted_at>=p_from) and (p_to is null or s.submitted_at<p_to) and (p_from is null or e.created_at>=p_from) and (p_to is null or e.created_at<p_to);
 select count(*) into activity_count from public.learning_sessions ls join public.enrolments e on e.student_id=ls.student_id and e.course_id=ls.course_id and e.status in ('active','completed') where ls.course_id=p_course_id and (p_from is null or ls.last_active_at>=p_from) and (p_to is null or ls.last_active_at<p_to) and (p_from is null or e.created_at>=p_from) and (p_to is null or e.created_at<p_to);
 select coalesce(jsonb_agg(jsonb_build_object('module_id',m.id,'module',m.title,'required_lessons',q.required_lessons,'completion_events',q.completion_events,'completion_rate',q.completion_rate) order by m.position),'[]'::jsonb) into module_rows
 from public.modules m cross join lateral (
   select count(distinct l.id) filter(where l.required) required_lessons,
     count(*) filter(where l.required and lp.completed_at is not null and (p_from is null or lp.updated_at>=p_from) and (p_to is null or lp.updated_at<p_to)) completion_events,
     round(100.0*count(*) filter(where l.required and lp.completed_at is not null and (p_from is null or lp.updated_at>=p_from) and (p_to is null or lp.updated_at<p_to))/nullif((count(distinct l.id) filter(where l.required))*learner_count,0),1) completion_rate
   from public.lessons l left join public.lesson_progress lp on lp.lesson_id=l.id and lp.student_id in (select e.student_id from public.enrolments e where e.course_id=p_course_id and e.status in ('active','completed') and (p_from is null or e.created_at>=p_from) and (p_to is null or e.created_at<p_to))
   where l.module_id=m.id
 ) q where m.course_id=p_course_id;
 select coalesce(jsonb_agg(jsonb_build_object('learner_alias',public._tutor_alias(p_course_id,e.student_id),'progress',e.progress,'completed_lessons',(select count(*) from public.lesson_progress lp join public.lessons l on l.id=lp.lesson_id join public.modules lm on lm.id=l.module_id where lm.course_id=p_course_id and lp.student_id=e.student_id and lp.completed_at is not null),'last_active_at',(select max(ls.last_active_at) from public.learning_sessions ls where ls.course_id=p_course_id and ls.student_id=e.student_id)) order by e.progress desc),'[]'::jsonb) into learner_rows
 from public.enrolments e where e.course_id=p_course_id and e.status in ('active','completed') and (p_from is null or e.created_at>=p_from) and (p_to is null or e.created_at<p_to);
 result:=jsonb_build_object('course_id',p_course_id,'period_start',p_from,'period_end',p_to,'learner_count',learner_count,'average_progress_percent',average_progress,'completed_learners',completion_count,'completion_rate_percent',round(100.0*completion_count/nullif(learner_count,0),1),'assessment_attempts',attempt_count,'assessments_reviewed',reviewed_count,'assessment_pass_rate_percent',round(100.0*passed_count/nullif(reviewed_count,0),1),'average_reviewed_score',average_score,'active_learning_sessions',activity_count,'modules',module_rows,'learners',learner_rows);
 return result;
end $$;
revoke all on function public.tutor_course_analytics(uuid,timestamptz,timestamptz) from public,anon;
grant execute on function public.tutor_course_analytics(uuid,timestamptz,timestamptz) to authenticated;

-- Consultation messages are always sent through this server-side guard. Detect
-- explicit name disclosure as well as common contact details and handles.
create or replace function public._send_course_consultation_message(p_consultation_id uuid,p_body text) returns uuid
language plpgsql security definer set search_path=public as $$
declare consultation_row public.course_consultations%rowtype; message_key uuid; lower_body text:=lower(coalesce(p_body,''));
begin
 select * into consultation_row from public.course_consultations where id=p_consultation_id;
 if consultation_row.id is null or auth.uid() not in (consultation_row.student_id,consultation_row.tutor_id) then raise exception 'Consultation access required'; end if;
 if not exists(select 1 from public.profiles p where p.id=auth.uid() and p.account_status='active' and ((auth.uid()=consultation_row.student_id and p.role='student') or (auth.uid()=consultation_row.tutor_id and p.role='tutor' and p.tutor_approved))) then raise exception 'Active consultation account required'; end if;
 if auth.uid()=consultation_row.tutor_id and not exists(select 1 from public.courses c where c.id=consultation_row.course_id and c.owner_id=auth.uid()) then raise exception 'Course is not assigned to this tutor'; end if;
 if consultation_row.status<>'open' then raise exception 'This consultation is closed'; end if;
 if length(trim(coalesce(p_body,'')))<1 or length(p_body)>3000 then raise exception 'Message must be between 1 and 3000 characters'; end if;
 if lower_body ~* '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' or lower_body ~* '(https?://|www\.|[a-z0-9-]+\.(com|net|org|io|co\.ug|ug)(/|\b))' or lower_body ~* '(^|[[:space:]])@[a-z0-9_.]{2,}' or lower_body ~* '(\+?[0-9][0-9 ()-]{7,}[0-9])' or lower_body ~* '(whatsapp|telegram|signal|instagram|facebook|snapchat|call me|text me|email me|my number|my contact|contact me)' or p_body ~* '\m(my name is|my name''s|i am called|i''m called)\M' or p_body ~ '\m(I am|I''m)\s+[A-Z][a-z]{2,}\M' then raise exception 'Names and contact details cannot be shared in tutor chat'; end if;
 insert into public.course_consultation_messages(consultation_id,sender_id,body) values(p_consultation_id,auth.uid(),trim(p_body)) returning id into message_key;
 update public.course_consultations set updated_at=now() where id=p_consultation_id;
 return message_key;
end $$;
revoke all on function public._send_course_consultation_message(uuid,text) from public,anon,authenticated;

create function public.tutor_course_enrolment_count(p_course_id uuid) returns bigint
language plpgsql stable security definer set search_path=public as $$
declare result bigint;
begin
 if not exists(select 1 from public.courses c join public.profiles p on p.id=c.owner_id where c.id=p_course_id and c.owner_id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active') then raise exception 'Course is not assigned to this tutor'; end if;
 select count(*) into result from public.enrolments where course_id=p_course_id and status in ('active','completed');
 return result;
end $$;
revoke all on function public.tutor_course_enrolment_count(uuid) from public,anon;
grant execute on function public.tutor_course_enrolment_count(uuid) to authenticated;
