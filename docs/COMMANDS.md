# Commands

This is an overview. Use `Get-Help <command> -Full` for every parameter.

## Connection

| Command | Purpose |
|---|---|
| `Connect-Untis [-Server] [-School] [-Credential] [-UserName] [-Secret] [-ApiMode] [-Save] [-PassThru]` | Log in |
| `Disconnect-Untis` | Log out, and clear session, credential and cache from memory |
| `Get-UntisConnection` | Show the connection, without secrets |
| `Test-UntisConnection [-Detailed] [-Server] [-School] [-Credential]` | Check DNS, HTTPS, authentication and API access |

## Timetable

### Get-UntisTimetable

```powershell
Get-UntisTimetable -Today
Get-UntisTimetable -Tomorrow
Get-UntisTimetable -Week [-WeekOffset 1]
Get-UntisTimetable -Date 2026-11-04
Get-UntisTimetable -FromDate 2026-11-03 -ToDate 2026-11-07
```

Add `-Class`, `-Teacher`, `-Student`, `-Room` or `-Subject` to select or filter, `-ExcludeCancelled` to hide cancelled lessons, and `-Force` to skip the cache.

WebUntis returns the timetable of one element per request, so filters work like this:

- The first of `-Student`, `-Class`, `-Teacher` and `-Room` selects whose timetable is requested.
- Any others filter that result.
- `-Subject` always filters. It applies to your own timetable unless you select another one.
- If your account can't look up teachers or rooms, `-Teacher` and `-Room` filter your own timetable instead, with a warning.

You can also pipe in a class, teacher, room, subject or student:

```powershell
Get-UntisClass 5a | Get-UntisTimetable -Week
```

Each result has these properties:

| Property | Type | Notes |
|---|---|---|
| `Date`, `StartTime`, `EndTime` | DateTime | School-local time |
| `Subject`, `Teacher`, `Room`, `Class` | String | Comma-separated if there are several. `NameStyle` selects short or long names |
| `LessonType` | String | `Lesson`, `OfficeHour`, `Standby`, `BreakSupervision`, `Exam` |
| `Status` | String | `Normal`, `Cancelled`, `Substitution`, `RoomChange`, `Irregular` |
| `IsCancelled` | Boolean | |
| `OriginalTeacher`, `OriginalRoom`, `OriginalSubject` | String | Set if changed |
| `LessonNumber`, `Id`, `ActivityType`, `LessonText`, `Info`, `SubstitutionText`, `StudentGroup` | | Details, where the server provides them |
| `Subjects`, `Teachers`, `Rooms`, `Classes` | Objects | Ids, short and long names |

### Format-UntisTimetable

```powershell
Get-UntisTimetable -Today | Format-UntisTimetable
Get-UntisTimetable -Week | Format-UntisTimetable -View Week
```

This returns text, so use it last in a pipeline. In the `Week` view, `(EN)` means cancelled and `GE*` means changed.

### Get-UntisLesson

Groups periods by lesson number, and shows counts and the next occurrence. The default range is the current week.

```powershell
Get-UntisLesson
(Get-UntisLesson -Subject MA).Periods
Get-UntisLesson -Id 9003 -Date 2026-11-04 | Format-List *
```

### Get-UntisNextLesson

```powershell
Get-UntisNextLesson
Get-UntisNextLesson -Count 3 -Subject MA
Get-UntisNextLesson -IncludeCurrent
```

Cancelled lessons are skipped unless you add `-IncludeCancelled`. The result has an extra `StartsIn` time span. The search covers 21 days by default, and `-LookAheadDays` changes this.

## Changes, exams and absences

### Get-UntisChanges

```powershell
Get-UntisChanges                  # this week
Get-UntisChanges -Today
Get-UntisChanges -Week -ChangeType Cancellation
Get-UntisChanges -Source Substitutions -Today -Class 5a
```

| `-Source` | Scope | Change types |
|---|---|---|
| `Timetable` | Your timetable, or the selected one | `Cancellation`, `Substitution`, `RoomChange`, `Irregular` |
| `Substitutions` | The whole school, if allowed | Also `Additional` and `Shifted`, with `RescheduledStart` and `RescheduledEnd` |
| `Auto` (default) | `Timetable` if there is one to read, otherwise `Substitutions` | |

### Get-UntisExam

```powershell
Get-UntisExam                     # next 30 days
Get-UntisExam -FromDate 2026-11-01 -ToDate 2026-11-30 -Subject 'Math*'
```

`Source` shows which API answered. `JsonRpc` results have no name, type or text. `WebApi` results do.

### Get-UntisAbsence

```powershell
Get-UntisAbsence                  # last 30 days
Get-UntisAbsence -FromDate 2026-09-01 -ToDate 2026-11-30 -Unexcused
```

`-Excused` and `-Unexcused` rely on the `IsExcused` value, which only the `WebApi` source provides.

## School data

`Get-UntisSubject`, `Get-UntisTeacher`, `Get-UntisRoom`, `Get-UntisClass` and `Get-UntisStudent` take an optional name, with wildcards, and `-Force`.

`Get-UntisSchoolYear [-Current]` and `Get-UntisHoliday` return `StartDate` and `EndDate`.

## Setup

| Command | Purpose |
|---|---|
| `Get-UntisConfiguration` | Show the effective settings |
| `Set-UntisConfiguration` | Save settings |
| `Reset-UntisConfiguration` | Delete the configuration file |
| `Save-UntisCredential`, `Remove-UntisCredential` | Manage the stored credential |
| `Clear-UntisCache` | Empty the cache |

## Diagnostics

`Get-UntisCapability` calls each read-only method once and reports `Available`, `NoPermission`, `NotOffered`, `Disabled` or `Error`. Its output has no school data, so it's safe to include in a bug report.

`Invoke-UntisApi` calls any JSON-RPC method that starts with `get`, and returns the raw result:

```powershell
Invoke-UntisApi -Method getStatusData
```

## Errors

Errors have the ID `UntisPS.<Kind>`, and the original code is in `$_.Exception.Data['UntisErrorCode']`. Kinds include `Authentication`, `SessionExpired`, `NoRight`, `DateNotAllowed`, `MethodNotFound`, `RateLimited`, `Transport`, `Http`, `InvalidResponse`, `Rpc`, `NotFound`, `Ambiguous`, `Argument`, `Configuration` and `NotConnected`.

```powershell
try {
    Get-UntisTeacher -ErrorAction Stop
} catch {
    if ($_.Exception.Data['UntisErrorKind'] -eq 'NoRight') { 'Not allowed at this school.' }
}
```
