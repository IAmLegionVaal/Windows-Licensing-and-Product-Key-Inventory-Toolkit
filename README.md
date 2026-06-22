# Windows Licensing and Product Key Inventory Toolkit

A PowerShell toolkit for legitimate Windows licensing inventory, activation diagnostics and guarded licensing repair, created by **Dewald Pretorius**.

## Files

- `Windows_Licensing_Product_Key_Toolkit.ps1` — licensing inventory, activation repair and sensitive OEM-key export.
- `Launch_Windows_Licensing_Toolkit.bat` — interactive technician menu.

## Diagnostic coverage

- Windows edition, version, build and architecture
- Windows licensing products and activation state
- Retail, OEM, volume or KMS channel details where Windows reports them
- Partial installed product keys
- KMS host and port configuration where present
- Software Protection Platform, Client License and License Manager services
- `slmgr /dlv` and `slmgr /xpr` evidence
- Masked OEM firmware product key when available

## Actual repair actions

- Start or restart available Windows licensing services.
- Request legitimate activation using the currently installed licence with `slmgr /ato`.
- Reinstall Windows system licence files with `slmgr /rilc`.
- Run DISM RestoreHealth.
- Run System File Checker.
- Open Activation Settings.
- Run service recovery and online activation as a combined workflow.

The repository does not contain activation bypasses, unofficial activation scripts, product-key generators or automatic third-party key installation.

## Usage

Diagnose only:

```powershell
.\Windows_Licensing_Product_Key_Toolkit.ps1 -Action Diagnose
```

Preview the repair workflow:

```powershell
.\Windows_Licensing_Product_Key_Toolkit.ps1 -Action RepairAllSafe -DryRun
```

Run legitimate licensing repair:

```powershell
.\Windows_Licensing_Product_Key_Toolkit.ps1 -Action RepairAllSafe
```

Reinstall system licence files:

```powershell
.\Windows_Licensing_Product_Key_Toolkit.ps1 -Action ReinstallLicenseFiles
```

Export the full OEM firmware key locally:

```powershell
.\Windows_Licensing_Product_Key_Toolkit.ps1 -Action ExportFullOemKey
```

## Sensitive-data handling

- OEM keys are masked in normal reports.
- Full OEM-key export requires typing `SENSITIVE`.
- The full key is written only to a restricted local folder.
- Sensitive key files and output folders are excluded by `.gitignore`.
- No product key from the uploaded ZIP has been committed.

## Safety

- Diagnostics are the default.
- Licensing repairs require administrator rights.
- Repairs require typing `REPAIR` unless `-Yes` is supplied.
- `-DryRun` previews actions.
- Trigger-start licensing services may stop again when idle; this is not automatically treated as failure.
- `slmgr /rilc`, DISM and SFC can take time and may require a restart before final validation.
- Online activation still requires a valid licence, correct edition, network access and a reachable activation service or KMS host.

## Validation status

The original OEM firmware-key lookup was tested successfully by the author on his own Windows machines. This repository preserves that working inventory action and adds legitimate Windows licensing service, `slmgr`, DISM and SFC recovery workflows. Results vary with Windows edition, licence channel, digital entitlement, KMS configuration, tenant policy, hardware changes and network access.

## Output

Each run creates a timestamped desktop folder containing:

- `before.json` and `after.json`
- Windows licence and service CSV files
- `slmgr /dlv` and `/xpr` output
- Activation or licence-file repair output when selected
- DISM and SFC output when selected
- `toolkit.log`

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | Completed successfully |
| 2 | OEM key or required Windows component unavailable |
| 4 | Elevation required |
| 10 | User cancelled |
| 20 | Licensing repair or verification failed |
