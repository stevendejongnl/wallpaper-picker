# wallpaper-picker

A wallpaper changer for Linux (X11) that fetches random wallpapers from
[Wallhaven](https://wallhaven.cc), applies them with `feh`, and — instead of
just silently swapping your background — can show a small GTK picker with
3 candidates so you can choose one, blacklist the ones you don't like
(deleted, never shown again), or shuffle for 3 new ones.

Runs standalone from a terminal/alias/`.desktop` launcher, or on a systemd
user timer (default every 3h, configurable, or turn it off and only run it
manually). Alternatively it can run once after boot and again after each
display profile change (see [Trigger modes](#trigger-modes)).

## Requirements

- Linux, X11 (uses `feh --bg-fill`)
- `feh`, `curl`, `jq`
- `python3` + PyGObject (GTK3) — only needed for `--gui`; every other mode
  is plain bash
- `systemd --user` — only needed for the timer; the script itself has no
  systemd dependency

## Install

```sh
git clone https://github.com/stevendejongnl/wallpaper-picker.git ~/.local/share/wallpaper-picker
~/.local/share/wallpaper-picker/install.sh
```

This symlinks the systemd units and `.desktop` launchers into place, seeds
`~/.config/wallpaper/{categories.conf,blacklist.txt}` from the examples if
you don't already have them, and enables the timer. Re-running is safe.

## Usage

```
wallpaper.sh                    fetch+set one wallpaper, no GUI (used by the timer if --gui isn't wired up)
wallpaper.sh --gui              show the picker: 3 candidates, blacklist / shuffle / set
wallpaper.sh --candidates N     fetch N candidates, print their paths (skips blacklisted ids)
wallpaper.sh --set FILE         apply FILE as the wallpaper
wallpaper.sh --blacklist FILE   blacklist FILE (by Wallhaven id, or path if local) and delete it
wallpaper.sh --reapply          re-apply the last-set wallpaper, no fetch, no GUI
wallpaper.sh -s / --select      pick from your local wallpapers directory interactively (terminal list)
wallpaper.sh -l / --local       force a random local wallpaper, skip the online fetch

wallpaper.sh --interval 1h      change the timer's auto-run interval (any systemd time span)
wallpaper.sh --mode periodic [span]  run the timer every span (default 3h)
wallpaper.sh --mode events      run after boot and after display profile changes only
wallpaper.sh --display-changed  open the picker if the mode is events (call from your profile switcher)
wallpaper.sh --timer-enable     turn automatic runs on
wallpaper.sh --timer-disable    turn automatic runs off -- manual invocation still works
wallpaper.sh --timer-status     show whether the timer is enabled and its current interval
```

`~/.config/wallpaper/categories.conf` is a plain list of Wallhaven search
queries, one per line; a random one is picked per candidate. Edit it any
time, no restart needed.

### Immich (optional)

Copy `config/immich.conf.example` to `~/.config/wallpaper/immich.conf`, set
`IMMICH_API_KEY`, and `chmod 600` it. It is off by default: the
picker only shows Wallhaven. Set `WALLPAPER_SOURCE=immich` (only Immich) or `mixed` (both)
for a run, e.g. `WALLPAPER_SOURCE=immich wallpaper.sh --gui`, or use the "Change Wallpaper
(Immich)" launcher. Candidates come from your Immich library, or from the albums in `IMMICH_ALBUM_IDS` (space separated,
combined into one pool) (landscape JPEGs only, blacklist works by asset id). The
internal URL is tried first with a 2 second timeout, so at home or on the home VPN
it stays on the LAN; otherwise the external URL is used. Without the file, only
Wallhaven is used.

To keep the key out of the file, leave `IMMICH_API_KEY` empty and set `IMMICH_BW_FIELD` (and
`IMMICH_BW_ITEM`, default `Immich`): the key is then read from that Bitwarden custom field via
`bw-session` at run time. The "Wallpaper Gallery (Immich)" launcher shows only the kept Immich
wallpapers (`WALLPAPER_SOURCE=immich wallpaper.sh --gallery`).

### The picker

`--gui` fetches 3 candidates and opens a window: click a thumbnail (or press
`1`/`2`/`3`) to select it, tick "Blacklist" under any you don't want to see
again, `Shuffle 3 new` for a fresh set, `Set` (or `Enter`) to apply, `Keep
current` (or `Escape`) to leave your wallpaper untouched. Ticked images are
blacklisted either way. If left alone for 3 minutes it keeps your current
wallpaper, so a timer-triggered run never hangs behind the window.

### Cache

Candidates are downloaded to `~/.cache/wallpaper/candidates/` and are not kept:
the folder is emptied on every fetch and when the picker closes. Only the one
you select is moved into `~/Pictures/wallpapers/online/`, and nothing is pruned
there. `~/Pictures/wallpapers/log.txt` keeps a rolling history (last 2000
lines).

## systemd units

`systemd/wallpaper.service` runs `wallpaper.sh --gui` once; `wallpaper.timer`
triggers it (30s after boot, then every `OnUnitActiveSec`, default 3h).
`install.sh` symlinks both into `~/.config/systemd/user/`. Adjust the
interval with `wallpaper.sh --interval <span>` rather than editing the timer
file directly — that writes a drop-in override so your change survives a
`git pull` of this repo.

### Trigger modes

- `periodic` (default): the timer runs the picker every 3h, or every span you
  pass to `--mode periodic <span>` / `--interval <span>`.
- `events`: `wallpaper.sh --mode events` removes the repeat. The picker runs
  once 30s after boot and again whenever your display profile switcher calls
  `wallpaper.sh --display-changed`. In `periodic` mode that call does nothing,
  so the hook is safe to leave in place.

Example for autorandr, at the end of the script that loads a profile (after
any profile choice is made):

```bash
"$HOME/.local/share/wallpaper-picker/bin/wallpaper.sh" --display-changed
```

`--mode periodic` without a span deletes the override and returns to the 3h
default. `--timer-status` shows the current mode.

## License

MIT, see [LICENSE](LICENSE).
