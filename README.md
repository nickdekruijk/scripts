# scripts

A handful of standalone command line tools I use day to day. There is nothing to
install and nothing shared between them: every script is self contained, and each
one carries its own documentation in the comment block at the top of the file.
Run any of them with `--help` (or `-h`) for the full option list.

## The scripts

| Script | What it does |
| --- | --- |
| [`db-sync.sh`](db-sync.sh) | Sync a database between a live server and your local environment. Pulls live to local by default, `--push` sends local to live. |
| [`db-clonio.sh`](db-clonio.sh) | The safe counterpart of `db-sync.sh`: pulls the live database with PII anonymized on the fly, via [Clonio](https://github.com/clonio-dev/clonio-cli). Unanonymized rows never touch disk. |
| [`clonio.pii-matchers.yaml`](clonio.pii-matchers.yaml) | Column name patterns that tell Clonio which fields hold personal data. Reference data for the above, not a script. |
| [`localpkg`](localpkg) | Swap a vendored `nickdekruijk/*` package for a local checkout beside the project, without touching `composer.json` or the lock file. |
| [`photoscan`](photoscan) | Scan several photos at once on a flatbed scanner and cut them apart into separate files. Detects, deskews and crops each photo. Bash plus SANE plus ImageMagick. |
| [`claude-backup`](claude-backup) | Archive and restore your local Claude Code history and setup, to carry it to a new machine. Caches and credentials are excluded. |
| [`claude-session-times`](claude-session-times) | Restore the mtime of Claude Code session files to when the conversation actually ended, so the resume picker is chronological again after an extension update. |
| [`rspamd-anon`](rspamd-anon) | Mask email addresses of your own domains in rspamd/exim logs with a stable salted hash, so you can share logs without leaking your users. External domains are left intact. |

## Requirements

Per script, roughly:

- `db-sync.sh`: SSH access to the server, `mysqldump` locally and remotely
- `db-clonio.sh`: the above, plus `clonio` on the `PATH` and a `.cloning.yaml` in the project
- `localpkg`: a Composer project with a `vendor/nickdekruijk/`, and the package checkouts in a `nickdekruijk/` folder next to the project
- `photoscan`: `sane-backends` and `imagemagick` (`brew install sane-backends imagemagick`)
- `claude-backup`, `claude-session-times`: Claude Code, and Python 3 for the latter
- `rspamd-anon`: a mail server with rspamd or exim, Perl, and write access to `/etc`

The two database scripts and `localpkg` are aimed at Laravel projects and read
local credentials from the project's `.env`.

## A note on the database scripts

Both talk to production. They read the remote credentials from the server's own
`.env` over SSH and keep them in memory, never on disk, but the connection itself
carries live data, so:

- The SSH host key is checked with `StrictHostKeyChecking=accept-new`. An unknown
  host is added silently, a *changed* host key is a hard error.
- `db-sync.sh --push` overwrites the live database. It asks you to type the live
  database name first, unless you pass `--force-push`.
- Prefer `db-clonio.sh` for anything you do not strictly need real data for.

## `CLAUDE.md`

[`CLAUDE.md`](CLAUDE.md) covers `photoscan` only. It documents the measured
behaviour of the scanner and the pitfalls in the detection pipeline, which are
the kind of thing that gets reverted by accident otherwise. It is written for
Claude Code, but it reads fine as a plain design document.

## License

MIT, see [LICENSE](LICENSE). Use them, break them, fix them.
