# UntisPS

UntisPS is a read-only PowerShell module for [WebUntis](https://webuntis.com). It gets timetables, changes, exams, absences and school master data, and returns them as PowerShell objects you can sort, filter, export and pipe.

UntisPS is an unofficial community project and is not affiliated with Untis GmbH.

> **Status: not yet tested against a live WebUntis server.** The test suite runs against mocks and a local HTTP server built from documented and community-observed behaviour. Run `Test-UntisConnection -Detailed` and `Get-UntisCapability` first on your school, and see [API limitations](#api-limitations).

## Requirements

- PowerShell 7 or later (recommended), or Windows PowerShell 5.1
- A WebUntis account at your school
- Optional: [Microsoft.PowerShell.SecretManagement](https://www.powershellgallery.com/packages/Microsoft.PowerShell.SecretManagement) with a vault, to store your password
- Optional, for tests: Pester 5.3 or later

The test suite ran on PowerShell 7.4 on Linux. Windows PowerShell 5.1 support is checked only statically, by tests that reject newer syntax. It has not been run on 5.1.

## Installation

Copy the `UntisPS` folder to your computer, then:

```powershell
Import-Module ./UntisPS/UntisPS.psd1
```

See [docs/INSTALLATION.md](docs/INSTALLATION.md) to install it permanently.

## First connection

Your server and school appear in the address bar when you open WebUntis in a browser. For `https://example.webuntis.com/WebUntis/?school=ExampleSchool#/basic/login`, they are `example.webuntis.com` and `ExampleSchool`.

```powershell
Import-Module ./UntisPS.psd1
Connect-Untis -Server "example.webuntis.com" -School "ExampleSchool"
Get-UntisTimetable -Today
Get-UntisTimetable -Week
Get-UntisChanges -Today
Get-UntisNextLesson
```

`Connect-Untis` asks for your user name and password. To skip the prompt next time:

```powershell
Connect-Untis -Server "example.webuntis.com" -School "ExampleSchool" -Save
# Later:
Connect-Untis
```

`-Save` needs secure storage, as described in [docs/AUTHENTICATION.md](docs/AUTHENTICATION.md). The password is never written to the configuration file.

**Two-factor authentication:** Untis has blocked the JSON-RPC API for users with 2FA since release 2025.4.1. See [docs/AUTHENTICATION.md](docs/AUTHENTICATION.md#accounts-with-two-factor-authentication) for the possible alternative.

## Command reference

| Area | Commands |
|---|---|
| Connection | `Connect-Untis`, `Disconnect-Untis`, `Get-UntisConnection`, `Test-UntisConnection` |
| Timetable | `Get-UntisTimetable`, `Format-UntisTimetable`, `Get-UntisLesson`, `Get-UntisNextLesson` |
| Changes and exams | `Get-UntisChanges` (alias `Get-UntisChange`), `Get-UntisExam`, `Get-UntisAbsence` |
| School data | `Get-UntisSubject`, `Get-UntisTeacher`, `Get-UntisRoom`, `Get-UntisClass`, `Get-UntisStudent`, `Get-UntisSchoolYear`, `Get-UntisHoliday` |
| Setup | `Get-UntisConfiguration`, `Set-UntisConfiguration`, `Reset-UntisConfiguration`, `Save-UntisCredential`, `Remove-UntisCredential`, `Clear-UntisCache` |
| Diagnostics | `Get-UntisCapability`, `Invoke-UntisApi` |

Every command has full help: `Get-Help Get-UntisTimetable -Full`. There is an overview in [docs/COMMANDS.md](docs/COMMANDS.md).

## Usage examples

```powershell
# One day, a range, or next week
Get-UntisTimetable -Date "2026-11-04"
Get-UntisTimetable -FromDate "2026-11-03" -ToDate "2026-11-07"
Get-UntisTimetable -Week -WeekOffset 1

# Someone else's timetable, if your account may read it
Get-UntisTimetable -Today -Class 5a
Get-UntisTimetable -Week -Teacher Miller
Get-UntisRoom A101 | Get-UntisTimetable -Today

# Your own timetable, filtered
Get-UntisTimetable -Week -Subject MA

# A grid to read
Get-UntisTimetable -Week | Format-UntisTimetable -View Week

# Objects stay objects
Get-UntisTimetable -Week | Where-Object IsCancelled
Get-UntisTimetable -Today | Format-Table StartTime, EndTime, Subject, Teacher, Room, Status
Get-UntisTimetable -Week | Export-Csv week.csv -NoTypeInformation

# Cancellations this week, and exams this month
Get-UntisChanges -Week -ChangeType Cancellation
Get-UntisExam -FromDate "2026-11-01" -ToDate "2026-11-30"

# What can this account do at this school?
Get-UntisCapability
```

There are runnable scripts in [examples/](examples/).

## Configuration

```powershell
Set-UntisConfiguration -Server example.webuntis.com -School ExampleSchool -NameStyle Long -DefaultRange Week
Get-UntisConfiguration
```

Settings are applied in this order: command parameter, environment variable, configuration file, default.

| Setting | Default | Environment variable | Meaning |
|---|---|---|---|
| `Server` | | `UNTIS_SERVER` | WebUntis host name |
| `School` | | `UNTIS_SCHOOL` | School identifier |
| `UserName` | | `UNTIS_USERNAME` | Default user name |
| `ApiMode` | `Auto` | `UNTIS_API_MODE` | `Auto` allows fallback to undocumented web-client endpoints. `JsonRpc` does not |
| `DefaultRange` | `Today` | | Range for `Get-UntisTimetable` without a date |
| `NameStyle` | `Short` | | `Short` (MA) or `Long` (Mathematics) |
| `HideCancelled` | `false` | | Hide cancelled lessons in `Get-UntisTimetable` |
| `CacheSeconds` | `60` | `UNTIS_CACHE_SECONDS` | Timetable cache, 0 to turn off |
| `MasterDataCacheSeconds` | `3600` | | Cache for teachers, rooms, classes and subjects |
| `TimeoutSeconds` | `30` | | Timeout per request |
| `MaxRetries` | `3` | | Retries after temporary failures |
| `MinRequestIntervalMs` | `100` | | Minimum gap between requests |

The file is at `%APPDATA%\UntisPS\config.json` on Windows and `~/.config/UntisPS/config.json` elsewhere. `UNTIS_CONFIG_PATH` overrides this. On Linux and macOS, `XDG_CONFIG_HOME` is respected.

There is deliberately no environment variable for the password. In automation, read the credential from a SecretManagement vault and pass it with `-Credential`.

## Troubleshooting

Start with:

```powershell
Test-UntisConnection -Detailed
Get-UntisCapability
```

| Problem | Likely cause and fix |
|---|---|
| `WebUntis rejected the credentials` | Wrong password, or the account uses 2FA. See [docs/AUTHENTICATION.md](docs/AUTHENTICATION.md) |
| `no right for getTeachers()` | The school does not let this account read that data. UntisPS cannot change that. Filters on your own timetable, such as `-Teacher`, still work |
| `no right for timetable` | Often a shared class account. UntisPS falls back to the class. If that fails too, use `-Class` |
| `This account has no personal timetable` | Select one with `-Class`, `-Room`, or similar |
| `does not allow this date range` | The dates are outside a school year the account can see. Check `Get-UntisSchoolYear` |
| `did not return JSON` | Wrong `-Server` or `-School`, or the server is in maintenance |
| `A previous automatic login failed` | Your password may have changed. Run `Connect-Untis` again. UntisPS stops here on purpose, so it cannot lock your account |
| Exams or absences are empty | They may simply be empty. `Source` on the results and `Get-UntisCapability` show which API answered |
| Next lesson is off by hours | Times are school-local and compared with this computer's clock. Run it in the school's time zone |

## API limitations

UntisPS uses the **WebUntis JSON-RPC API** as its main interface, plus a small number of **undocumented web-client endpoints** as a fallback. The **Untis Platform API** is not used, because it is for integration partners and needs activation by a school administrator. It is not available to individual users.

- Rights depend on your school and role. Student accounts are often refused teacher lists, exams and school-wide substitutions.
- Untis calls the JSON-RPC API "old". No end date has been found, but it may change or go away.
- Web-client endpoints have no public contract, and can change without notice. Set `ApiMode` to `JsonRpc` to avoid them.
- UntisPS is read-only. It cannot submit absences, or change anything else.
- JSON-RPC has no pagination, so UntisPS has none. Long ranges mean large responses.
- Neither API publishes rate limits, so limits are handled by reacting to HTTP 429 and spacing requests.

The full matrix, with sources and confidence levels, is in [docs/API-COMPATIBILITY.md](docs/API-COMPATIBILITY.md).

## Security considerations

- Passwords are never written to configuration files, logs or verbose output. There is no password parameter on any configuration command.
- While connected, the credential and session stay in memory so UntisPS can log in again after a session expires. `Disconnect-Untis` removes them.
- Only HTTPS is used, and certificates are validated by the platform. There is no option to disable this. Redirects are not followed.
- Server input is validated. A warning appears before a password is sent to a host outside `webuntis.com`.
- Failed logins are never retried, and one failed automatic login blocks further attempts until you reconnect.
- Cached data stays in memory and is cleared on disconnect. Absences are never cached.
- There is no scraping or browser automation.
- Timetables, absences and student lists are personal data, often of minors. Handle exports accordingly, and follow your school's rules.

## Tests

```powershell
./tests/Invoke-Tests.ps1
```

The suite needs no credentials or network access. All fixtures are fictional.

## License

[MIT](LICENSE)
