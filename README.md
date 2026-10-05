# watermark-worker

A tiny, dependency-free FFmpeg job that overlays a **watermark image** and a
**watermark text** onto a video file, then uploads the result elsewhere.
Position, motion (static / moving / spin), light-dark style, size and opacity
are all caller-controlled.

## How it works

1. A caller triggers `repository_dispatch` (type `watermark`) with a payload:

   | field       | meaning                                            |
   |-------------|----------------------------------------------------|
   | `srcUrl`    | presigned GET url of the source video              |
   | `dstUrl`    | presigned PUT url of the destination object        |
   | `logoUrl`   | optional PNG/JPG/WebP url, overlaid on the video   |
   | `siteName`  | optional plain-ASCII text rendered on the video    |
   | `srcExt`    | optional source extension (default `mp4`)          |
   | `name`      | optional label used in logs                        |
   | `logoPos`   | `tl|tr|bl|br|c` (default `tr`)                     |
   | `logoMotion`| `static|moving|spin` (default `static`)            |
   | `textPos`   | `tl|tr|bl|br|c` (default `br`)                     |
   | `textMotion`| `static|moving` (default `static`)                 |
   | `textStyle` | `light|dark` (default `light`)                     |
   | `textSize`  | `s|m|l` (default `m`)                              |
   | `op`        | opacity 0.20–1.00 (default `0.85`)                 |

2. The workflow downloads the source, burns the watermark with FFmpeg
   (`libx264 ultrafast`, `yuv420p`, `faststart` — phone-gallery friendly),
   verifies the output, and uploads it to `dstUrl`.

## Security model

- **No credentials live here.** Both URLs are short-lived and signed by the
  caller; this repository only contains the ffmpeg invocation.
- `permissions: {}` — the job has no GitHub token rights.
- Runs on the free `ubuntu-latest` runner, one video at a time per
  destination key (concurrency group).
