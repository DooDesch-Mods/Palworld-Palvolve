# Publishing automation

Automated distribution to Thunderstore and Nexus Mods via the "Publish release"
GitHub Actions workflow (`.github/workflows/publish.yml`). The Steam Workshop is
NOT covered here - it stays with the official PalworldModUploader.

## How it works

Nexus Mods: publishing a GitHub release triggers the workflow automatically.
It downloads the release zip, extracts this version's section from CHANGELOG.md
and uploads the file via the official Nexus-Mods/upload-action - the changelog
text becomes the file version's release notes and the mod version is bumped to
match. Creating the release is the explicit go; there is no separate publish
step anymore. While `nexus.fileId` or the API key secret are missing, the Nexus
steps skip with a notice instead of failing the release.

Known platform limit: the mod page's separate "Changelogs" tab has no write
endpoint in the Upload API yet (authors are waiting for it). Until Nexus ships
that, the per-file release notes carry the changelog; extend the workflow when
the endpoint appears.

Thunderstore: manual only (workflow_dispatch). A dispatch run downloads the
release zip, repacks it into a Thunderstore package
(`publishing/build-thunderstore.sh`, unreal-shimloader layout with the required
`enabled.txt`) and stores everything as a workflow artifact. Publishing only
happens when its checkbox is ticked for that run, so a plain run is a dry run.

Release flow: tag + GitHub release with asset `Palvolve-v<version>.zip` - done.

## One-time setup

Same conventions as the ScheduleOne pipelines: the API key is the org secret,
the file group id is an Actions variable, the changelog section is converted
to BBCode for the Nexus file description.

Org secrets (already set on DooDesch-Mods):

- `TCLI_AUTH_TOKEN`: Thunderstore service account token.
- `NEXUSMODS_API_KEY`: personal API key from the Nexus Mods account settings
  (the Upload API is in open beta).

Repo/org variable:

- `NEXUS_FILE_GROUP_ID`: create the mod page on Nexus manually once
  (description: `Workspace/releases/Palvolve/nexus/`), upload the first file
  through the website, then read the file id from "API Info" on the Files tab
  and store it as this variable. The Nexus steps skip with a notice until it
  is set.

Config (`publishing/publish-config.json`):

- `thunderstore.team`: must match the Thunderstore team/namespace exactly.
- `nexus.modId`: page reference (nexusmods.com/palworld/mods/7680216).

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
