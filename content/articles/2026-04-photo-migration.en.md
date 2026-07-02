---
title: "3x Smaller: Centralizing and Cleaning 194 GB of Photos with an LLM"
date: 2026-07-02T07:23:38+02:00
slug: photo-migration-llm
cover:
  image: /images/2026/06-immich/cover.jpeg
tags: [immich, photos, llm, claude, opencode, glm, migration, self-hosted]
---

After years of accumulating photos and videos across both iCloud and Google
Photos, I decided to self-host everything on
[Immich](https://immich.app/) - an excellent open-source Google Photos
alternative that I'm self-hosting
([deployment manifests](https://github.com/clementnuss/k8s-gitops/tree/main/workloads/appl-n8r/immich)). \
Setting up Immich itself was straightforward.
The real challenge was how badly organized my pictures were: \
some were on iCloud, some on Google Photos, some on random SD cards,
some on Drive folders, some were pictures missing proper EXIF metadata,
some were embedding a live video, some file names had collisions, some
videos had poor encoding and were huge, some were duplicated, some ... \
This is the story of how I used an LLM assistant throughout that process -
mostly [Claude Code](https://docs.anthropic.com/en/docs/claude-code), and later
also [OpenCode](https://opencode.ai/) with GLM-5.2.

## Why an LLM?

Sorting pictures, fixing metadata, re-encoding, etc are tasks that can be done
pretty well from the CLI, given that you know which tools to use and how to use
them. But because there are so many pictures in so many folders and a plethora
of file formats, while it would be possible to sort everything by hand or with
a script, you would need to spend hours to write dozens of scripts to do that
work. \
Some examples: parse this metadata, rename those files, convert these videos,
deduplicate across two directories. Each step reveals edge cases you didn't
anticipate, and for which yet another script is required.

So rather than writing and debugging all of these scripts myself, I used
Claude Code (and later OpenCode with GLM-5.2). I'd describe what I needed
("build a staging directory with hard links from both sources"), it would write
a Python script, run it, and show me the results. When something went wrong -
and things went wrong regularly - I'd describe the problem and get a fix within
seconds.

## The cleaning process

Step 0 was retrieving all my pictures to my laptop: easier said than done! For
Google Photos, [Google Takeout](https://takeout.google.com/) was highly
helpful. For iCloud, Apple doesn't provide any simple way to export all
pictures, so I went with using [icloud_photos_downloader](https://github.com/icloud-photos-downloader/icloud_photos_downloader) (though I recently
learnt about [kei](https://github.com/rhoopr/kei) which might be both faster
and more reliable in hindsight). And for the other pictures spread around, I
just had to copy everything to my base folder.

Once that was done, the actual work started: the LLM came up with the smart idea
that we would have a `staging` folder in which we would put the
filtered/cleaned up media files, and another smart idea to link files (from the
original to the staging folder) whenever possible. That way, through the
multiple iterations that this process required, my originals never changed and
the staging folder was rebuilt a few times until I was satisfied.

For the actual cleanup process, we did the following:

- Used `jdupes` to remove byte-level duplicates
- Ensured all files had a proper EXIF timestamp set
- Renamed all files with a date prefix, like `YYYYMMDD_HHMMSS_original.ext`
- Converted poorly encoded videos to HEVC (where bitrate per pixel > 0.3) -
saved 27 GiB
- Converted some images to HEIC (bytes-per-pixel heuristic: > 0.6 re-encoded) -
saved 19 GiB

The most interesting part was the edge cases. After importing a first batch into
Immich, I noticed that some Live Photos were mismatched - a video from my iPhone
was paired with a completely unrelated photo. It turned out that my Canon EOS
R10 uses the same `IMG_XXXX` naming pattern as the iPhone. Since Immich matches
Live Photo pairs by filename, it was happily pairing Canon stills with iPhone
videos, which is why we had to date-prefix every single file.

## What surprised me

What made this task tractable (and actually fun) was the speed at which the LLM
adapted to edge cases. Each step revealed some edge case, and I could just
describe what I needed - "these files have the wrong date, check the EXIF"
— and have a fix in seconds. No context-switching to write a script, no
debugging: just describe the problem and review the result.

Giving the agent access to the Immich API was what really closed the loop. When
something was off in the Immich UI, I'd describe it, and the LLM could query the
API to find the bad assets, delete them, fix the staging files, and re-import -
all without me leaving the terminal.

## The result

194 GB of scattered, duplicated, bloated media became 60 GB of clean,
deduplicated, properly timestamped files - organized by year and imported into
Immich. For the first time, everything is in one place, at home, and backed up
every night to 2 different S3 providers with kopia.

## The AGENTS.md

Here's the trimmed-down `AGENTS.md` I used to guide Claude Code (and OpenCode)
through this migration:

<details>
<summary>AGENTS.md</summary>

```markdown
# Photo Migration Staging — iCloud + Google Takeout → Immich

A runbook for importing personal media from iCloud and Google Takeout into a self-hosted Immich instance. No code, no build system — media files, hardlink trees, and ad-hoc Python/CLI operations. Two migrations completed so far: ~7,796 iCloud files (2012–2026) and a second library (2014–2026). Across both, ca. 194 GB of source media was reduced to ~60 GB after deduplication and HEVC/HEIC conversion, producing 10,489 media files + 123 XMP sidecars organized by year.

## Key directories

- `by_year/` — **Import-ready** hardlinks organized by year (2012–2026 + undated). This is what gets uploaded to Immich.
- `combined/` — Flat date-prefixed hardlinks (source of truth for `by_year/`).
- `icloud/`, `takeout/` — Original hardlinks from source exports. Deduplicated in place.
- `album_<name>/` — Hardlinks of a named album, all stamped with a single date for Immich album creation (optional, for albums you want to reconstruct).
- `raw_with_processed/` — RAW files + processed companions (staged, not yet imported).
- `migration_logs/` — Conversion logs (if present).

## Tools

Python 3, exiftool, ffmpeg, ImageMagick (`magick`), jdupes, Immich CLI (`npx @immich/cli`), `file --mime-type` for extensionless identification.

## Runbook for a new source

Pipeline order (do these in sequence — date-prefixing early prevents cascading filename-collision and Live-Photo-mispairing issues):

1. **Stage hardlinks** from the source export into a per-source subdirectory (`icloud/`, `takeout/`, …) using `os.link()`. Skip `.json` sidecars. Apply any source-specific exclusion sets up front (see source-specific notes below).
2. **Deduplicate** across _all_ source dirs together with `jdupes -r -d -N`.
3. **Date-prefix** every file to `YYYYMMDD_HHMMSS_originalname.ext` using the timestamp priority below. This is the single most important step — do it before conversion so EXIF recovery and collision resolution have stable filenames to work from.
4. **Convert** videos (H.264 → HEVC) and images (JPEG/PNG/TIF → HEIC) using the heuristics below. Recover EXIF after every video conversion.
5. **Verify metadata** on every converted file: `DateTimeOriginal` present, mtime matches, date prefix matches. Catch mismatches before they propagate.
6. **Organize by year** into `by_year/YYYY/` (+ `undated/`) using hardlinks from `combined/`.
7. **Import year by year** to Immich. Verify Live Photo pairing after the first batch.

## Source-specific notes

### iCloud (`icloud/`)

- Walked year folders, hardlinked all media to `icloud/`.
- Apply an exclusion set up front for any albums you don't want imported (e.g. photobooth dumps, duplicates of an event already captured by another photographer). Skipping ~2,410 files this way saved significant downstream work.

### Google Takeout (`takeout/`)

- Walked album + `Photos de YYYY` folders, hardlinked to `takeout/`.
- **Paths contain `\xa0`** (non-breaking space in `Google\xa0Photos`). `os.link()` and `os.walk()` may silently fail. Use `subprocess.run(['find', ...])` to resolve actual paths.
- **`.heic.jpg` files are Takeout re-exports** of HEIC originals — duplicates, not distinct images. Delete them.
- **Google Motion Photos embed video in the JPEG** (XMP `MicroVideo: 1`). The standalone `.MP4` from Takeout is redundant — delete it.
- **Takeout strips `.MOV` extensions from Live Photo videos.** Files like `IMG_2451` (no extension) alongside `IMG_2451.HEIC` are the video companion. Use `file --mime-type` to identify and add `.MOV`.
- **Takeout re-exports can differ from iCloud originals.** Same photo from iCloud (`.JPG`) and Takeout (`.jpg`) may have different file sizes due to re-compression. `jdupes` won't catch them as duplicates. Check for cross-source dupes by UUID filename after import.

## Critical gotchas

- **Hardlinks everywhere.** All staging uses `os.link()`, not `shutil.copy2()`. Modifying one hardlink affects all links to the same inode. Never copy when a hardlink will do — disk is tight (~194 GB original → ~60 GB after conversion).
- **`exiftool -overwrite_original` breaks hardlinks.** It writes a new inode. After using exiftool on a file in `by_year/`, the matching hardlink in `combined/` is no longer the same inode. This is acceptable but be aware.
- **ffmpeg strips ALL EXIF timestamps from MP4/MOV.** `exiftool -DateTimeOriginal -s3` returns empty on video files even before conversion — MP4/MOV containers use `QuickTime:ContentCreateDate`/`QuickTime:CreateDate` instead of EXIF. After video conversion, always write `DateTimeOriginal` from the **filename** (since it's the only reliable source), then set mtime.
- **Multiple devices share `IMG_XXXX` naming** (e.g. Canon EOS 550D and iPhone). Overlapping counters cause Immich to mispair Live Photos across devices. Always date-prefix filenames before import.
- **Live Photo `.MOV` files must never be video-converted.** They are companion tracks paired by filename with `.HEIC`/`.JPG` stills.
- **Immich falls back to `fileCreatedAt` when `DateTimeOriginal` is missing.** Files without EXIF show as the upload/download date. Always verify EXIF exists on every file before importing — write `DateTimeOriginal` from filename if missing.
- **Use exiftool batch mode.** For thousands of files, always use `-stay_open True` batch mode. Single-invocation-per-file is orders of magnitude slower.
- **Verify metadata after every bulk operation.** Cross-check converted files against originals and date prefixes. On one migration all 1,623 converted files were verified — 0 mismatches. Don't skip this.

## File naming convention

All files in `combined/` and `by_year/` use: `YYYYMMDD_HHMMSS_originalname.ext`

Timestamp priority:

1. EXIF `DateTimeOriginal`
2. Google Takeout JSON sidecar (`photoTakenTime.timestamp`) — found as `{filename}.supplemental-metadata.json` or `.supp.json`
3. Filename pattern (e.g., `20200527_124912.HEIC`)
4. Falls back to `undated/`

## Conversion recipes

### Video: H.264 → HEVC (never convert Live Photo MOVs)

Run `ffmpeg -i input.mp4 -c:v libx265 -preset medium -crf 23 -tag:v hvc1 -c:a copy output.mp4`.

- `-tag:v hvc1` required for Apple compatibility. `-c:a copy` preserves audio without re-encoding.
- Always recover EXIF after conversion (write `DateTimeOriginal` from filename, set mtime).
- Only convert where `bitrate_per_pixel = file_size / (width * height * duration)` is high (>0.3). Short/low-bitrate videos won't benefit and may get larger.
- Also downscale HEVC 4K → 1080p; skip HEVC ≤1080p (already efficient).
- Reference result: 372 videos converted, ~27 GB saved.

### Images → HEIC (use bpp heuristic, don't convert blindly)

Compute bytes-per-pixel: `bpp = file_size_bytes / (width * height)` — e.g. with Python PIL as `os.path.getsize(path) / (im.width * im.height)`.
Only convert if `bpp > 0.6`. Quality 60 via `magick input.jpg -quality 60 output.heic`.
For oversized originals (e.g. 8256×5504 DSLR photos), add `-resize 3840x2560`. Set mtime from EXIF `DateTimeOriginal` after conversion.

Reference tiers used on one migration (review each batch before proceeding):

| Tier           | Threshold                   | Files | Savings |
| -------------- | --------------------------- | ----- | ------- |
| Bloated files  | bpp > 1                     | 265   | ~3.9 GB |
| Camera JPEGs   | bpp > 0.6                   | 603   | ~6.5 GB |
| DSLR 4K photos | bpp > 0.6 + downscale to 4K | 815   | ~8.8 GB |

### Bulk exiftool

Always use `-stay_open True` batch mode — single-invocation-per-file is orders of magnitude slower.

## icloudpd

Use the git version of [icloud_photos_downloader](https://github.com/icloud-photos-downloader/icloud_photos_downloader). Session cookies live under `~/.pyicloud/` (`.cookie` + `.session` files per account). Reauthentication is required periodically; loop the download command to handle intermittent failures.

## Deduplication

`jdupes -r -d -N <dir>` — run across both `icloud/` and `takeout/` together for cross-source dedup by content hash — no filename assumptions needed.

## Immich import

`npx @immich/cli upload -r -c 4 --key $IMMICH_API_KEY --server https://your-immich-instance/api by_year/YYYY/`
Import year by year. Verify Live Photo pairing after first batch. API endpoints for cleanup: `/api/search/metadata` (POST with JSON body), `/api/assets` (DELETE with `{"ids":[...],"force":true}`). When bad files are already imported, use the API to find and delete them programmatically rather than clicking through the UI.
```

</details>

## Honest take

Staying with Google Photos or iCloud would have been perfectly fine. Neither
platform was failing me. What I'm genuinely happy about after this migration
is that I've **centralized everything** and **filtered and processed** the data
in the process. Years of duplicate photos, bloated formats, and scattered albums
are now clean and organized.
