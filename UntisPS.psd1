@{
    RootModule           = 'UntisPS.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '7f3f6a55-6a0c-4a57-9d4e-2c6a1d0b4e21'
    Author               = 'UntisPS contributors'
    CompanyName          = 'Community'
    Copyright            = '(c) UntisPS contributors. MIT License.'
    Description          = 'Read-only PowerShell client for WebUntis: timetables, changes, exams, absences and master data. Unofficial; not affiliated with Untis GmbH.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FormatsToProcess     = @('UntisPS.Format.ps1xml')
    FunctionsToExport    = @(
        'Connect-Untis', 'Disconnect-Untis', 'Get-UntisConnection', 'Test-UntisConnection',
        'Save-UntisCredential', 'Remove-UntisCredential',
        'Get-UntisConfiguration', 'Set-UntisConfiguration', 'Reset-UntisConfiguration',
        'Get-UntisTimetable', 'Format-UntisTimetable',
        'Get-UntisLesson', 'Get-UntisNextLesson',
        'Get-UntisChanges', 'Get-UntisExam', 'Get-UntisAbsence',
        'Get-UntisSubject', 'Get-UntisTeacher', 'Get-UntisRoom', 'Get-UntisClass', 'Get-UntisStudent',
        'Get-UntisSchoolYear', 'Get-UntisHoliday',
        'Get-UntisCapability', 'Invoke-UntisApi', 'Clear-UntisCache'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('Get-UntisChange')
    PrivateData          = @{
        PSData = @{
            Tags         = @('WebUntis', 'Untis', 'Timetable', 'School', 'Education', 'PSEdition_Desktop', 'PSEdition_Core', 'Windows', 'Linux', 'MacOS')
            ReleaseNotes = 'See CHANGELOG.md'
        }
    }
}
