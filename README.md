# Omnissa Horizon / UAG certificate automation

This package automates:
1. Request/renew a Let's Encrypt certificate on Windows using win-acme (formerly letsencrypt-win-simple)
2. Validate DNS through AWS Route 53
3. Export a `.pfx`
4. Upload that `.pfx` to an Omnissa Unified Access Gateway (UAG)

## Files
- `renew-and-push-uag.ps1` — PowerShell automation script
- `settings.example.json` — copy to `settings.json` and fill in secrets
- `.gitignore` — prevents secrets and generated cert material from being committed
- `task-scheduler-example.xml` — importable Windows Task Scheduler example
- `uploader-site.html` — simple local browser UI wrapper around the same script

## Assumptions
- UAG admin REST API is reachable on `https://<uag>:9443/rest`
- UAG version supports REST admin APIs (2503+ is the documented Omnissa API line)
- win-acme with Route53 plugin is installed
- AWS credentials have permission to edit `_acme-challenge` TXT records in Route 53

## win-acme notes
The current maintained successor to letsencrypt-win-simple is **win-acme / wacs.exe**.
Its Route53 unattended flags are documented as:
- `--validation route53`
- `--route53accesskeyid ...`
- `--route53secretaccesskey ...`

The `.pfx` store plugin is documented by win-acme as supported.

## Suggested Windows layout
Use a dedicated folder such as:
- `C:\CertAutomation\renew-and-push-uag.ps1`
- `C:\CertAutomation\settings.json`
- `C:\CertAutomation\certs\horizon.misfirm.com.pfx`

## How to use
1. Install win-acme pluggable build and Route53 validation plugin.
2. Copy `settings.example.json` to `settings.json`.
3. Update secrets and paths.
4. Run PowerShell as admin:
   ```powershell
   .\renew-and-push-uag.ps1 -ConfigPath .\settings.json
   ```
5. Confirm the UAG receives the new certificate.
6. Import `task-scheduler-example.xml` into Windows Task Scheduler and adjust the schedule/account.

## Scheduling recommendation
- Run monthly, not only near expiry.
- Use a service account with permission to:
  - run `wacs.exe`
  - write the PFX output path
  - reach Route 53
  - reach `https://10.227.2.20:9443`
- Keep `settings.json` out of git.

## Important
The exact UAG certificate upload endpoint/payload can vary by UAG release. This script centralizes that in `Invoke-UagCertificateUpload`; adjust that function if your appliance expects a different REST path or field names.

## Security recommendations
- Revoke and rotate any PAT or cloud secret that was pasted into chat or shell history.
- Prefer temporary credentials, Windows Credential Manager, or environment variables over long-lived secrets in files when possible.
- Protect the generated `.pfx` with a strong password.
