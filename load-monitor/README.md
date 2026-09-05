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

## What a snapshot contains

The familiar part first: `top`, connections per IP, processes in D state and
the MySQL processlist (non-sleeping rows only, with a count of the sleeping
ones). Then the six blocks that answer the questions which otherwise come up
the morning after:

1. **Memory per account and per process name.** Who holds the memory, in MB.
   Note that RSS counts shared memory once per process, so nginx with a big
   ModSecurity ruleset looks several times larger than it really is.
2. **php-fpm workers per pool.** Which pool is full right now, without
   waiting for the `max_children reached` line in the fpm log.
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
   that shows a request before it is finished and logged.

## Two things about server-status

**Read it from Apache, not through the proxy.** On a `nginx_apache` setup the
page has to come from Apache's own port (`STATUS_URL`, TLS on 8081 by
default). Any healthy vhost serves it because `<Location /server-status>` is
global, but on DirectAdmin the default vhost answers with a silent 500 and
non-www names with a 301 to www. So `STATUS_HOSTS` lists a couple of www
hostnames and the first that returns the real page wins. Prefer hostnames you
control: a customer domain works until the customer leaves.

**The password is not where you think.** CustomBuild protects the page with
basic auth and writes the generated password only as a hash to
`/var/www/passwd-server-status`. Nobody has it in plain text. Set your own:

```sh
htpasswd -b /var/www/passwd-server-status info 'your-password'
```

and put it in `STATUS_PW`. If the block ever reports a 401, CustomBuild has
regenerated it; repeat both steps. The rest of the snapshot keeps working
either way.

## Parsing note

The scoreboard rows in the HTML span several source lines, so a line-based
`sed` sees a row end after the `M` column and the request columns never show
up. Join the table into one line first, then split on `</tr>`. With
`ExtendedStatus On` the columns are `4=M 6=SS 12=Client 14=VHost 15=Request`.
This cost an hour once, hence the note.

## Requirements

bash, `flock`, `ss`, `vmstat`, `curl`, `top`, and a `mysql` client for the
processlist. GNU `date` and `/proc`, so Linux only.
