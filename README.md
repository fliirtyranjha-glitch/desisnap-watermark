# watermark-worker

A tiny, dependency-free FFmpeg job that overlays a **logo** (top-right) and a
**site name** (bottom-right) onto a video file, then uploads the result
elsewhere.

## How it works

1. A caller triggers `repository_dispatch` (type `watermark`) with a payload:

   | field     | meaning                                        |
   |-----------|------------------------------------------------|
   | `srcUrl`  | presigned GET url of the source video          |
   | `dstUrl`  | presigned PUT url of the destination object    |
   | `logoUrl` | optional public PNG url, overlaid top-right    |
   | `siteName`| optional plain-ASCII text, rendered bottom-right|
   | `srcExt`  | optional source extension (default `mp4`)      |
   | `name`    | optional label used in logs                    |

2. The workflow downloads the source, burns the watermark with FFmpeg
   (`libx264 ultrafast`, `yuv420p`, `faststart` — phone-gallery friendly),
   verifies the output, and uploads it to `dstUrl`.

## Security model

- **No credentials live here.** Both URLs are short-lived and signed by the
  caller; this repository only contains the ffmpeg invocation.
- `permissions: {}` — the job has no GitHub token rights.
- Runs on the free `ubuntu-latest` runner, one video at a time per
  destination key (concurrency group).
