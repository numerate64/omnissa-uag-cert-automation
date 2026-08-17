# Omnissa Horizon / UAG certificate automation

This package automates:
1. Request/renew a Let's Encrypt certificate on Windows using win-acme (formerly letsencrypt-win-simple)
2. Validate DNS through AWS Route 53
3. Export a `.pfx`
4. Upload that `.pfx` to an Omnissa Unified Access Gateway (UAG)

## Files
- `renew-and-push-uag.ps1` — PowerShell automation script
- `settings.example.json` — copy to `settings.json` and fill in secrets
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

## How to use
1. Install win-acme pluggable build and Route53 validation plugin.
2. Copy `settings.example.json` to `settings.json` and fill in values.
3. Run PowerShell as admin:
   ```powershell
   .\\renew-and-push-uag.ps1 -ConfigPath .\\settings.json
   ```
4. If successful, schedule it monthly in Windows Task Scheduler.

## Important
The exact UAG certificate upload endpoint/payload can vary by UAG release. This script centralizes that in `Invoke-UagCertificateUpload`; adjust that function if your appliance expects a different REST path or field names.
