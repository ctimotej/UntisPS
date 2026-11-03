# API compatibility

Research date: 2026-11-03. **Nothing here has been verified against a live WebUntis server**, because neither a school account nor network access to WebUntis was available during development. Use `Get-UntisCapability` to see the real situation for your account.

## Interfaces investigated

| Interface | Status | Access | Used by UntisPS |
|---|---|---|---|
| **JSON-RPC API** (`/WebUntis/jsonrpc.do`) | Documented by Untis in a PDF given to schools. Release notes call it "the old JSON-RPC API" | User name and password. Not for users with 2FA | Yes, the primary interface |
| **Web-client endpoints** (`/WebUntis/api/...`) | Undocumented, used by the WebUntis web app, and known from community clients | Session cookie | Yes, as a fallback in `ApiMode` `Auto` |
| **Internal app endpoint** (`/WebUntis/jsonrpc_intern.do`) | Undocumented, known from community clients | User name and a personal app secret | Only for `Connect-Untis -Secret` |
| **Untis Platform API** (`api.webuntis.com`) | Official and current, with a published changelog | OAuth/OpenID Connect. Needs a registered platform application, activated by a school administrator | No |
| **REST view API** (`/WebUntis/api/rest/view/...`) | Undocumented, used by the web app. One community client warns that it differs between tenants and roles | Session plus JWT | No |

### Why not the official Platform API?

It is the only interface with a current official contract, and a future version should look at it again. It does not fit today because it is built for integration partners: an application is registered in the Platform Application Manager, and each school's administrator must activate it. A student, parent or teacher running a local module cannot do this. We also found no public description of the data endpoints, only the authentication flow and a changelog, so implementing it would have meant guessing.

Schools that have a platform application can ask Untis about it. Partner documentation is at [help.untis.at](https://help.untis.at/hc/de/articles/4403351094034-General-documentation-for-integration-partners).

## Evidence levels

- **Official**: stated by Untis in material we read directly.
- **Documented**: in the JSON-RPC API, per several independent community clients that follow the Untis PDF. **We could not read the PDF itself**, so this is second-hand.
- **Observed**: used by community clients, with no public contract.

## Feature matrix

| Feature | Command | Source | Evidence | Depends on school or role? |
|---|---|---|---|---|
| Login, logout | `Connect-Untis`, `Disconnect-Untis` | `authenticate`, `logout` | Documented | 2FA users are blocked (Official) |
| Own or element timetable | `Get-UntisTimetable` | `getTimetable` | Documented | Yes. Shared accounts may get `no right for timetable` |
| Lessons, next lesson | `Get-UntisLesson`, `Get-UntisNextLesson` | Built from `getTimetable` | Documented | As above |
| Personal changes | `Get-UntisChanges` | `code` and `orgid`/`orgname` fields of `getTimetable` | Documented | As above |
| School-wide changes | `Get-UntisChanges -Source Substitutions` | `getSubstitutions` | Documented | Yes |
| Exams | `Get-UntisExam` | `getExams`, then `/WebUntis/api/exams` | Documented, then Observed | Yes |
| Absences | `Get-UntisAbsence` | `getTimetableWithAbsences`, then `/WebUntis/api/classreg/absences/students` | Documented, then Observed | Yes |
| Subjects, rooms, classes | `Get-UntisSubject`, `Get-UntisRoom`, `Get-UntisClass` | `getSubjects`, `getRooms`, `getKlassen` | Documented | Yes |
| Teachers | `Get-UntisTeacher` | `getTeachers` | Documented | Yes. `-8509` for students is widely reported |
| Students | `Get-UntisStudent` | `getStudents` | Documented | Yes |
| School years, holidays | `Get-UntisSchoolYear`, `Get-UntisHoliday` | `getSchoolyears`, `getCurrentSchoolyear`, `getHolidays` | Documented | Probably not |
| Secret login | `Connect-Untis -Secret` | `jsonrpc_intern.do` | Observed | Unknown whether it works for 2FA accounts |

## Not implemented

| Feature | Reason |
|---|---|
| Writing data (absences, messages) | UntisPS is read-only by design |
| Homework, messages, news | Web-client only and not in scope. They could be added later |
| Anonymous access | The community method relies on a hard-coded value. Left out until there is a cleaner basis |
| Pagination | JSON-RPC has none |
| Form login (`j_spring_security_check`) | Too close to scraping for this project |
| Finding a school by name | Undocumented endpoint, and the browser's address bar already gives the answer |

## Known uncertainties

The code handles these defensively, but they could not be confirmed:

- **Error codes.** Only `-8504`, `-8509`, `-8520`, `-7004`, `-8507` and `-32601` are mapped, because those are the ones found in community clients or reports. Other codes pass through with the server's own message.
- **2FA failure.** Release notes confirm the block but not the error returned. UntisPS mentions 2FA in its bad-credentials message for this reason.
- **`orglongname`.** Whether this field exists is not confirmed. If it is absent, long-name mode shows the short name for an original teacher or room.
- **`getTimetable` for masked data.** Some schools hide teachers from students. Such lessons show an empty teacher.
- **Exam details.** `getExams` returns ids only, so `Name`, `ExamType` and `Text` are empty from that source. The web-client source fills them.
- **Rate limits.** No published limits were found.
- **Session lifetime.** About ten minutes of idle time, according to community clients. UntisPS doesn't rely on the exact value: it reacts to `-8520`.
- **Web-client session expiry.** It's assumed to appear as HTTP 401, 403 or a redirect, based on one community client.

## Sources

Official:

- [WebUntis release notes](https://help.untis.at/hc/en-150/articles/360008456699-WebUntis-Release-Notes): 2025.4.1 states that the old JSON-RPC API can no longer be called by a user with 2FA.
- [General documentation for integration partners](https://help.untis.at/hc/de/articles/4403351094034-General-documentation-for-integration-partners)
- [Platform authentication](https://help.untis.at/hc/de/articles/4886722226834)
- [Platform API changelog](https://help.untis.at/hc/de/articles/4886890048658)

Community:

- [python-webuntis](https://github.com/python-webuntis/python-webuntis): methods, error codes, period and substitution fields
- [SchoolUtils/WebUntis](https://github.com/SchoolUtils/WebUntis): login flows, cookies, web-client endpoints
- [webuntis-api (Ruby)](https://github.com/Meow/webuntis-api): session recovery and an overview of the API surfaces
- [webuntis-api-docs](https://github.com/SafeMemoryZone/webuntis-api-docs): protocol notes
- [Keule0010/WebUntisAPI](https://github.com/Keule0010/WebUntisAPI): substitution and exam fields
- [homeassistant-WebUntis #328](https://github.com/JonasJoKuJonas/homeassistant-WebUntis/issues/328) and [#92](https://github.com/JonasJoKuJonas/homeassistant-WebUntis/issues/92): `-8509` in practice, and the class-timetable workaround
