# Authentication

## Password login

```powershell
Connect-Untis -Server example.webuntis.com -School ExampleSchool
```

The credential is taken from the first of these that exists:

1. `-Credential`
2. A stored credential for this server and school
3. A prompt

UntisPS keeps the credential in memory while connected, because WebUntis drops idle sessions and UntisPS has to log in again. `Disconnect-Untis` removes it.

## Storing a credential

```powershell
Save-UntisCredential -Server example.webuntis.com -School ExampleSchool
# Or at login:
Connect-Untis -Server example.webuntis.com -School ExampleSchool -Save
```

| Environment | Where it goes |
|---|---|
| SecretManagement is installed | Your default vault, as a secret named `UntisPS:<server>:<school>` |
| Windows without SecretManagement | A DPAPI-encrypted file next to the configuration file. Only the same user on the same computer can read it |
| Linux or macOS without SecretManagement | Refused. There is no secure fallback, and UntisPS will not store plaintext |

To set up a vault:

```powershell
Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope CurrentUser
Register-SecretVault -Name LocalVault -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
```

To remove a stored credential, run `Remove-UntisCredential`.

## Unattended scripts

Read the credential from a vault, then pass it:

```powershell
$credential = Get-Secret -Name 'UntisPS:example.webuntis.com:exampleschool'
Connect-Untis -Server example.webuntis.com -School ExampleSchool -Credential $credential
```

Check how your vault unlocks when nobody is at the keyboard. SecretStore asks for a password by default.

## Accounts with two-factor authentication

The WebUntis release notes for version 2025.4.1 say: "The old JSON-RPC API can no longer be called with a user for whom 2FA is activated." Password login therefore cannot work for these accounts, and the error you get may simply look like wrong credentials.

There are two options:

1. **Ask your school** for a separate account without 2FA for automation, if school policy allows it.
2. **Try the app secret.** This uses the personal key behind the QR code in your WebUntis profile, which the Untis Mobile app also uses:

   ```powershell
   $secret = Read-Host 'WebUntis app secret' -AsSecureString
   Connect-Untis -Server example.webuntis.com -School ExampleSchool -UserName jamie.doe -Secret $secret
   ```

This option has real limits:

- It uses an undocumented internal app endpoint, which can change without notice.
- Whether it works for an account with 2FA is **unknown**, and it hasn't been tested on a live server.
- The secret works like a password. Keep it in a vault, and never in a script.
- Check that your school allows it. If it doesn't, don't use it.

UntisPS doesn't save `-Secret` values. Keep yours in a SecretManagement vault and pass it in.

## Session handling

- If WebUntis reports an expired session, UntisPS logs in again once and repeats the call.
- If that login fails, UntisPS stops logging in until you run `Connect-Untis`. This protects your account from being locked by repeated attempts.
- Failed logins are never retried. Only temporary network and server problems are.
- Please disconnect when you are done, so that the server can free the session. Untis asks applications to do this.

## What is never stored or logged

Passwords, app secrets, session cookies and tokens are not written to the configuration file, logs, verbose output or error messages. `Get-UntisConnection` doesn't expose them. Server messages are scrubbed for anything that looks like a credential before they're shown.

`-Verbose` shows the HTTP method and path only.
