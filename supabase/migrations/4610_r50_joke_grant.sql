-- r50: 4310 took EXECUTE on app.academy_questions_joke() away from PUBLIC; every app function stays callable by
-- service_role (the server), as base test 06 checks.
grant execute on function app.academy_questions_joke() to service_role;
