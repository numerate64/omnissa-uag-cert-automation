# Omnissa Horizon / UAG Certificate Automation

Automation for the MIS Horizon certificate flow:

1. Run win-acme (`wacs.exe`) on the Windows certificate server `10.227.2.21`.
2. Complete Let's Encrypt DNS validation through AWS Route 53.
3. Export renewed certificate files.
4. Push the certificate to the Omnissa Unified Access Gateway at `10.227.2.20`.

The public Horizon endpoint is `https://horizon.misfirm.com:8443`.

Static runbook page: https://numerate64.github.io/omnissa-uag-cert-automation/uploader-site.html

## Files

- `renew-and-push-uag.ps1` - main PowerShell automation.
- `Initialize-WinAcmeRoute53Renewal.ps1` - one-time setup helper that prompts for AWS keys and creates the win-acme renewal profile.
- `settings.example.json` - redacted sample config; copy to `settings.json` and fill in local secrets.
- `task-scheduler-example.xml` - monthly Windows Task Scheduler example.
- `uploader-site.html` - local operator page with copyable commands.

## Recommended Install Path

On `10.227.2.21`, create:

```powershell
New-Item -ItemType Directory -Force C:\CertAutomation
New-Item -ItemType Directory -Force C:\CertAutomation\certs
```

Copy these files into `C:\CertAutomation`, then:

```powershell
Copy-Item C:\CertAutomation\settings.example.json C:\CertAutomation\settings.json
notepad C:\CertAutomation\settings.json
```

Keep `settings.json` private. It contains UAG and PFX credentials. AWS Route 53 credentials should be entered only into win-acme during renewal profile setup.
The script also supports `UagPasswordProtected` and `PfxPasswordProtected` values encrypted with Windows DPAPI, which is better for scheduled runs than storing plaintext passwords.

## win-acme / Chocolatey

The Chocolatey shim on `10.227.2.21` points to an older win-acme build that cannot read the current renewal JSON. Use the working pluggable build that is already on the server:

```text
C:\Users\cmoreira-adm\Documents\Projects\omnissa-uag-cert-automation\wacs-2.2.9.1701\wacs.exe
```

If you later install a newer win-acme centrally, update `WinAcmePath` in `settings.json`.

The MIS server already has a production win-acme renewal profile:

```json
"UseExistingWinAcmeRenewal": true,
"WinAcmeRenewalId": "AMuObaWrKU-cy35FmVJdTw",
"WinAcmeBaseUri": "https://acme-v02.api.letsencrypt.org/"
```

With that setting, the script calls `wacs.exe --renew --id AMuObaWrKU-cy35FmVJdTw` and reuses the existing encrypted win-acme Route 53/PFX configuration. Leave the AWS fields blank in `settings.json` for the normal path.

For a clean setup or key rotation, create the renewal profile with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\CertAutomation\Initialize-WinAcmeRoute53Renewal.ps1 -ConfigPath C:\CertAutomation\settings.json
```

That command prompts for the Route 53 access key and secret, then lets win-acme store the secret in its encrypted store under `C:\ProgramData\win-acme`. After it completes, copy the printed renewal ID into `WinAcmeRenewalId`.

You need the win-acme build/plugin that supports Route 53 validation and PEM file output. The config uses:

```text
--validation route53
--route53accesskeyid
--route53secretaccesskey
--store pemfiles
--pemfilespath C:\CertAutomation\certs
--pemfilesname horizon.misfirm.com
```

win-acme's PEM store writes `{name}-crt.pem`, `{name}-key.pem`, `{name}-chain.pem`, and `{name}-chain-only.pem`. The script sets `{name}` to `horizon.misfirm.com`, so the default upload paths are:

```json
"FullChainPemPath": "C:\\CertAutomation\\certs\\horizon.misfirm.com-chain.pem",
"PrivateKeyPemPath": "C:\\CertAutomation\\certs\\horizon.misfirm.com-key.pem"
```

If the existing win-acme renewal exports only `horizon.misfirm.com.pfx`, the script can derive the PEM key and chain from that PFX before uploading to UAG. Keep `PfxPath` and either `PfxPassword` or `PfxPasswordProtected` populated for that mode.

## UAG Upload Mode

The default is:

```json
"UagUploadMode": "Pem",
"UagCertificateTargets": ["END_USER"]
```

That uses the long-standing UAG REST endpoints:

```text
PUT https://10.227.2.20:9443/rest/v1/config/certs/ssl/END_USER
PUT https://10.227.2.20:9443/rest/v1/config/certs/ssl/ADMIN
```

For the public Horizon certificate, `END_USER` is usually the correct target. Add `ADMIN` only if you also want the UAG admin console certificate replaced.

There is also a configurable `Pfx` mode for UAG versions/environments where you have validated a PFX REST endpoint. Change `UagUploadMode` to `Pfx` and adjust `UagPfxEndpointTemplate` if needed.

## Test Safely

Validate config and paths:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\CertAutomation\renew-and-push-uag.ps1 -ConfigPath C:\CertAutomation\settings.json -ValidateOnly
```

Renew/export only, without touching UAG:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\CertAutomation\renew-and-push-uag.ps1 -ConfigPath C:\CertAutomation\settings.json -SkipUpload
```

Upload existing cert files only:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\CertAutomation\renew-and-push-uag.ps1 -ConfigPath C:\CertAutomation\settings.json -UploadOnly
```

Full run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File C:\CertAutomation\renew-and-push-uag.ps1 -ConfigPath C:\CertAutomation\settings.json
```

Logs are written to `C:\CertAutomation\logs`.

## Schedule

Run monthly. Let's Encrypt certificates are short-lived, and monthly renewal keeps the process exercised before an emergency.

Import `task-scheduler-example.xml`, set the task account, and confirm it can:

- Run `wacs.exe`.
- Write `C:\CertAutomation\certs` and `C:\CertAutomation\logs`.
- Update `_acme-challenge.horizon.misfirm.com` records in Route 53.
- Reach `https://10.227.2.20:9443`.

## AWS IAM Scope

Use a dedicated AWS access key with the smallest practical Route 53 policy. It should only be able to list the hosted zone, submit TXT changes needed for DNS-01 validation, and check Route 53 change status. Do not commit AWS keys or store them in `settings.json` for the normal renewal path.

## Notes

- `UagVerifyTls` is `false` in the example because UAG admin interfaces often use private or self-signed certificates. Set it to `true` once the automation host trusts the UAG admin certificate.
- The script redacts sensitive command-line values in its own log, but win-acme may still log details separately. Protect the logs folder.
- The Omnissa developer portal lists UAG REST APIs and current API versions, and Omnissa KB 91732 confirms the UAG certificate must match the public FQDN and include the private key.
