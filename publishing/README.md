# Publishing automation

Automated distribution to Thunderstore and Nexus Mods via the "Publish release"
GitHub Actions workflow (`.github/workflows/publish.yml`). The Steam Workshop is
NOT covered here - it stays with the official PalworldModUploader.

## How it works

The workflow is manual only (workflow_dispatch). It downloads the zip asset of an
existing GitHub release, repacks it into a Thunderstore package
(`publishing/build-thunderstore.sh`, unreal-shimloader layout with the required
`enabled.txt`) and stores everything as a workflow artifact. Publishing to a
platform only happens when its checkbox is ticked for that run, so a plain run is
a dry run.

Release flow: tag + GitHub release first (asset `Palvolve-v<version>.zip`), then
run the workflow with the version number.

## One-time setup

Repository (or org) secrets:

- `TCLI_AUTH_TOKEN`: Thunderstore service account token. Create the team on
  thunderstore.io, then Team > Service Accounts > Add Service Account.
- `NEXUSMODS_API_KEY`: personal API key from the Nexus Mods account settings
  (the Upload API is in open beta).

Config (`publishing/publish-config.json`):

- `thunderstore.team`: must match the Thunderstore team/namespace exactly.
- `nexus.modId` / `nexus.fileId`: create the Palvolve mod page on Nexus manually
  once (description: `Workspace/releases/Palvolve/nexus/`), upload the first
  file through the website, then read both ids from "API Info" on the Files tab
  and store them here. The workflow updates that file entry on every run.

## Publish policy

Palvolve is only published to platforms where PalSchema is available as a
dependency: Steam Workshop, GitHub and Nexus Mods. Without PalSchema on the
platform, the schema half of the mod (workbench, stones, recipes) cannot reach
the user.

- Thunderstore: NOT published. PalSchema is missing from the Palworld community
  (checked 17.07.2026) and unreal_shimloader virtualizes its own RE-UE4SS,
  which is unverified against Palworld 1.0. The Thunderstore path in the
  workflow stays dormant (checkbox off); revisit only if PalSchema appears on
  Thunderstore AND a shimloader test profile proves compatibility.
- CurseForge: NOT published for the same reason - PalSchema is not hosted
  there (checked 17.07.2026).

## Listing texts

Thunderstore listing assets live in `publishing/thunderstore/` (README shown on
the package page, manifest description, 256x256 icon derived from the Workshop
thumbnail). The master copies of all platform texts are maintained in the
workspace under `Workspace/releases/Palvolve/<platform>/`.
