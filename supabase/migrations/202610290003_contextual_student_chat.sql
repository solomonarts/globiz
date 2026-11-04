-- Student conversations begin from a lesson or module. Their subject comes from
-- the selected learning content, never from user supplied text.
create or replace function public.student_start_course_consultation(
 p_course_id uuid,p_module_id uuid,p_lesson_id uuid,p_subject text,p_body text
) returns uuid language plpgsql security definer set search_path=public as $$
declare tutor_key uuid; consultation_key uuid; subject_key text;
begin
 if not exists(select 1 from public.profiles where id=auth.uid() and role='student' and account_status='active') then raise exception 'Active student access required'; end if;
 if p_module_id is null and p_lesson_id is null then raise exception 'Start a conversation from a lesson or module'; end if;
 if not exists(select 1 from public.enrolments where student_id=auth.uid() and course_id=p_course_id and status in ('active','completed')) then raise exception 'Active course enrolment required'; end if;
 select owner_id into tutor_key from public.courses where id=p_course_id and status='published';
 if tutor_key is null then raise exception 'Course consultation is unavailable'; end if;
 if p_module_id is not null and not exists(select 1 from public.modules where id=p_module_id and course_id=p_course_id) then raise exception 'Module does not belong to this course'; end if;
 if p_lesson_id is not null then
   select l.title into subject_key from public.lessons l join public.modules m on m.id=l.module_id where l.id=p_lesson_id and m.course_id=p_course_id and (p_module_id is null or m.id=p_module_id);
   if subject_key is null then raise exception 'Lesson does not belong to this course'; end if;
 else
   select title into subject_key from public.modules where id=p_module_id and course_id=p_course_id;
 end if;
 if subject_key is null then raise exception 'Lesson or module is required'; end if;
 if length(subject_key)>160 then subject_key:=left(subject_key,157)||'…'; end if;
 insert into public.course_consultations(student_id,tutor_id,course_id,module_id,lesson_id,subject)
 values(auth.uid(),tutor_key,p_course_id,p_module_id,p_lesson_id,subject_key) returning id into consultation_key;
 perform public._send_course_consultation_message(consultation_key,p_body);
 return consultation_key;
end $$;
revoke all on function public.student_start_course_consultation(uuid,uuid,uuid,text,text) from public,anon;
grant execute on function public.student_start_course_consultation(uuid,uuid,uuid,text,text) to authenticated;

-- Assigned tutors can follow lesson completion by pseudonymous learner alias.
create or replace function public.tutor_course_learner_progress(p_course_id uuid)
returns table(learner_alias text,progress numeric,last_active_at timestamptz,lessons jsonb)
language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from public.courses c join public.profiles p on p.id=c.owner_id where c.id=p_course_id and c.owner_id=auth.uid() and p.role='tutor' and p.tutor_approved and p.account_status='active') then raise exception 'Course is not assigned to this tutor'; end if;
 return query
 select public._tutor_alias(p_course_id,e.student_id),e.progress,ls.last_active_at,
  coalesce((select jsonb_agg(jsonb_build_object('module',m.title,'lesson',l.title,'completed',lp.completed_at is not null,'updated_at',lp.updated_at) order by m.position,l.position)
   from public.modules m join public.lessons l on l.module_id=m.id left join public.lesson_progress lp on lp.lesson_id=l.id and lp.student_id=e.student_id
   where m.course_id=p_course_id and l.required),'[]'::jsonb)
 from public.enrolments e left join public.learning_sessions ls on ls.course_id=e.course_id and ls.student_id=e.student_id
 where e.course_id=p_course_id and e.status in ('active','completed')
 order by ls.last_active_at desc nulls last,public._tutor_alias(p_course_id,e.student_id);
end $$;
revoke all on function public.tutor_course_learner_progress(uuid) from public,anon;
grant execute on function public.tutor_course_learner_progress(uuid) to authenticated;
