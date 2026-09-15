# load-monitor

Logs the load average every minute and, when it is high, captures a snapshot
of what the server is doing at that moment: to the cron mail, as before, and
to a file on disk, which is the part that was missing.

It replaced a php cron script that had run for years. The mail it sent was the
only record of an incident, and mail gets deleted. When two weeks of load
spikes had to be reconstructed afterwards, the three biggest ones had no
snapshot left and everything had to be inferred from `sar` and log archives.
The old script also restarted nginx and Apache at load 6, which on a box with
ModSecurity cost about a minute of CPU and, keyed off the lagging one-minute
average, regularly fired a second time when the real problem was already
over. The second peak in those mails was the restart itself.

## Files

| File | Goes to |
| --- | --- |
| [`load-monitor`](load-monitor) | `/usr/local/sbin/load-monitor`, mode 700 |
| [`load-monitor.conf.example`](load-monitor.conf.example) | `/etc/load-monitor.conf`, mode 600 |
| [`cron.example`](cron.example) | `/etc/cron.d/load-monitor`, mode 644 |

## Install

```sh
install -m 700 load-monitor /usr/local/sbin/load-monitor
install -m 600 load-monitor.conf.example /etc/load-monitor.conf
$EDITOR /etc/load-monitor.conf      # SELF_IPS, STATUS_HOSTS, STATUS_PW at least
install -m 644 cron.example /etc/cron.d/load-monitor

load-monitor debug                  # forces a snapshot at any load, read it
ls -la /var/log/load-snapshots/
```

Test with `LC_ALL=C` if your shell is not already in that locale, the way
cron runs it. The script sets it for itself, but the point is to see what
cron will see.

## nginx-only servers (Laravel Forge)

The script was written on a DirectAdmin box and also runs on plain nginx ones.
Everything DirectAdmin-specific is switched off from the config file, so the
script itself stays identical on every machine:

```sh
STATUS_URL=""                            # no Apache, skips block 6
STATUS_HOSTS=""
MYSQL_CONF=""                            # root reaches MySQL over socket auth
DOMAIN_LOGS=""                           # no per-domain access logs
ACCESS_LOGS="/var/log/nginx/access.log"
FPM_LOGS="/var/log/php*-fpm.log"
```

Two blocks behave differently as a result. Block 5 reads the combined log and
still reports client IPs, status codes and user agents, but the domain
breakdown is gone: nginx's default `combined` format has no `$host`, and
putting one there means editing the web server config of a live machine.

`ACCESS_LOGS` takes more than one file, space separated, and then block 5
labels every request with the log it came from and counts per log file. That
is as close to a per-site split as a Forge box gets without touching nginx.
Sites there rarely share one log neatly: Forge's template writes
`access_log off;` in the server block, and whoever needed a log for one site
added an `access_log` line to that vhost alone. On the leguesswho box, for
instance, `leguesswho.com` writes its own file, eight other vhosts log nothing
at all, and only the catch-all still lands in the global `access.log`:

```sh
ACCESS_LOGS="/var/log/nginx/access.log /var/log/nginx/leguesswho.com-access.log"
```

Before trusting that list, check which vhosts actually log. Do not grep for
`access_log off` in a vhost file: every Forge template carries
`location = /favicon.ico { access_log off; ... }`, so that matches everywhere
and makes it look as if no site logs. Look for an `access_log` line at server
level, outside any `location` block. For a site that logs nothing, its
`*-error.log` is the only trace left.

Block 6 is skipped and **block 7** answers the same question in its place: for
every php-fpm pool, how many established connections its unix socket has right
now, which is how many requests that pool is executing at this instant. It does
not show which URL each one is; that needs `pm.status_path` on every pool plus
an nginx location. Note that only the local-address column of `ss` carries the
socket path, because the nginx end of the same connection lists it as its peer.
Filtering the whole line counts every request twice.

If the box cannot send mail, set `MAILTO=""` in the cron file. Otherwise every
snapshot lands in `/var/mail/root` forever. The snapshots on disk are then the
record, so make sure something else tells you a spike happened at all.

## What a snapshot contains

The familiar part first: `top`, connections per IP, processes in D state and
the MySQL processlist (non-sleeping rows only, with a count of the sleeping
ones). Then the six blocks that answer the questions which otherwise come up
the morning after:

1. **Memory per account and per process name, and who sits in swap.** Who holds
   the memory, in MB. Note that RSS counts shared memory once per process, so
   nginx with a big ModSecurity ruleset looks several times larger than it
   really is. The swap list is `VmSwap` per process name plus the total: a full
   swapfile with nothing paging in is slow, not an emergency, and `vmstat`
   below says which of the two this is.
2. **php-fpm workers per pool.** Which pool is full right now. The pool name
   comes from the process title, the only place it appears; `comm` is just
   `php-fpm8.3` and would merge every pool of one version into a single line.
   With `FPM_LOGS` set, the last few `max_children reached` warnings are shown
   underneath, with their own timestamps, so read them as history and not as
   part of this spike.
3. **`vmstat 1 3`.** Whether this is a swap storm (`si`/`so`), plus run queue
   and iowait on one line. `sar` only has ten-minute averages.
4. **OOM killer.** The last five kernel messages, because a killed `mysqld`
   explains a lot and nobody thinks to look.
5. **Web traffic of the last two minutes.** Top domains, client IPs, status
   codes and user agents, from only the access logs that were written to in
   that window, so it stays cheap on a busy server. Per-domain access logs on
   DirectAdmin are emptied nightly; if you keep an archive, this is the block
   that tells you which day to open.
6. **Apache server-status.** The requests in flight at that moment, with
   vhost, client and how many seconds each has been running. The only source
   that shows a request before it is finished and logged. Skipped when
   `STATUS_URL` is empty.
7. **php-fpm requests in flight.** The same question on a box without Apache:
   established connections per pool socket, which is what each pool is
   executing right now. No URLs, only counts.

## Two things about server-status

**Read it from Apache, not through the proxy.** On a `nginx_apache` setup the
page has to come from Apache's own port (`STATUS_URL`, TLS on 8081 by
default). Any healthy vhost serves it because `<Location /server-status>` is
global, but on DirectAdmin the default vhost answers with a silent 500 and
non-www names with a 301 to www. So `STATUS_HOSTS` lists a couple of www
hostnames and the first that returns the real page wins. Prefer hostnames you
control: a customer domain works until the customer leaves.

**The password is regenerated on every rewrite.** CustomBuild protects the
page with basic auth, generates the password, and writes it to
`/etc/httpd/conf/extra/httpd-info.conf.secret` as `# Username:` and
`# Password:` lines. Every `./build rewrite_confs` replaces both the hash and
that file, so a password copied into a config breaks on the next rewrite.
The script therefore reads the file at runtime (`STATUS_PW_FILE`). Set
`STATUS_PW` only if you manage the password yourself with `htpasswd -b`. If
the block ever reports a 401 anyway, the two files disagree; the rest of the
snapshot keeps working either way.

## Parsing note

The scoreboard rows in the HTML span several source lines, so a line-based
`sed` sees a row end after the `M` column and the request columns never show
up. Join the table into one line first, then split on `</tr>`. With
`ExtendedStatus On` the columns are `4=M 6=SS 12=Client 14=VHost 15=Request`.
This cost an hour once, hence the note.

## Requirements

bash, `flock`, `ss`, `vmstat`, `curl`, `top`, and a `mysql` client for the
processlist. GNU `date` and `/proc`, so Linux only.
