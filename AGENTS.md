# clement.n8r.ch — Personal Blog

Hugo static site using the [PaperMod](https://github.com/adityatelange/hugo-PaperMod) theme.

## Languages

- **French (default)**: files end in `.fr.md`
- **English**: files end in `.en.md`
- Articles can exist in one or both languages.
- Each section needs an `_index.fr.md` and/or `_index.en.md` to generate listing pages.

## Content structure

- `content/articles/` — blog posts (YAML frontmatter with `---`)
- `content/talks/` — conference talks (TOML frontmatter with `+++`)
- `static/images/` — small images bundled in the site container
- `media/` — large files (HD pictures, PDFs) synced to S3 and served at `https://media.n8r.ch/...`

## Images

- Small images: place in `static/images/<topic>/` and reference as `/images/<topic>/file.jpg`
- Large/HD images: place in `media/` and reference as `https://media.n8r.ch/<path>` (mirroring the `media/` folder structure)
- Do NOT put large images in `static/` — they bloat the container.

### Image optimization (ImageMagick)

Keep images in `static/images/` small — the whole folder ships in the site
container. Targets applied across the repo (see `git log` for reference):

- Talk thumbnails / article images: max width 1600px, JPEG quality 80
- Text-heavy screenshots (dashboards, terminal output): resize to 1600px and
  quantize PNG to 256 colors, or use WebP q85 if quantization isn't a win

```sh
# photos / talk thumbnails -> JPEG q80, max 1600px wide, EXIF stripped
magick input.png -auto-orient -resize '1600x>' -strip -quality 80 output.jpeg

# text-heavy screenshots -> quantized PNG (keeps text crisp)
magick input.png -auto-orient -resize '1600x>' -strip -colors 256 output.png
```

Only shrink if the result is actually smaller (check the file size, e.g. with
`stat -c%s`); keep the original if not. If a conversion renames the file,
update all references in `content/` (including `.fr.md` twins).

## Media sync (S3)

The `media/` folder is synced to an S3 bucket via rclone (config in `hack/s3.rclone`).

Before syncing, source the credentials:

```sh
source ~/git/github.com/clementnuss/dev-docs/blog/credentials
rclone sync media/ s3-remote: --config hack/s3.rclone   # adjust to your rclone remote name
```

Slides PDFs for talks go in `media/pdfs/<year>/` and must be synced before the
`slides_url` links work publicly.

## Building

```sh
hugo          # build the site (output in public/)
hugo server   # local dev server at http://localhost:1313
```

## Article frontmatter (YAML)

```yaml
---
title: "Article Title"
date: 2026-01-01T12:00:00+01:00
slug: article-slug
cover:
  image: /images/topic/cover.jpg   # or https://media.n8r.ch/...
tags: [tag1, tag2]
---
```

## Talk frontmatter (TOML)

```toml
+++
title = "Talk Title"
description = "Event name"
tags = ["Talk"]
draft = false
date = "2026-01-01T10:00:00+02:00"
author = "Clément Nussbaumer"
image = "/images/talks/image.jpeg"
slides_url = "https://media.n8r.ch/pdfs/..."
recording_url = "https://youtube.com/..."
+++
```
