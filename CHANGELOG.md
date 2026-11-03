# Changelog

## 0.1.0 - 2026-11-03

First release. Not yet tested against a live WebUntis server.

### Added

- Login with password or personal app secret, session recovery and logout
- Timetables by day, week or range, with class, teacher, student, subject and room selection
- Lessons, next lesson, changes, exams and absences
- Subjects, teachers, rooms, classes, students, school years and holidays
- Default table views and `Format-UntisTimetable`
- Configuration through parameters, environment variables and a file
- Secure credential storage through SecretManagement or Windows DPAPI
- Timeouts, retries, Retry-After handling, request spacing and an in-memory cache
- `Test-UntisConnection`, `Get-UntisCapability` and `Invoke-UntisApi`
