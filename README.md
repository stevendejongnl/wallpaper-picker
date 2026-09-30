# wallpaper-picker

A wallpaper changer for Linux (X11) that fetches random wallpapers from
[Wallhaven](https://wallhaven.cc), applies them with `feh`, and — instead of
just silently swapping your background — can show a small GTK picker with
3 candidates so you can choose one, blacklist the ones you don't like
(deleted, never shown again), or shuffle for 3 new ones.

Runs standalone from a terminal/alias/`.desktop` launcher, or on a systemd
user timer (default every 3h, configurable, or turn it off and only run it
manually).

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
wallpaper.sh --timer-enable     turn automatic runs on
wallpaper.sh --timer-disable    turn automatic runs off -- manual invocation still works
wallpaper.sh --timer-status     show whether the timer is enabled and its current interval
```

`~/.config/wallpaper/categories.conf` is a plain list of Wallhaven search
queries, one per line; a random one is picked per candidate. Edit it any
time, no restart needed.

### The picker

`--gui` fetches 3 candidates and opens a window: click a thumbnail (or press
`1`/`2`/`3`) to select it, tick "Blacklist" under any you don't want to see
again, `Shuffle 3 new` for a fresh set, `Set` (or `Enter`) to apply, `Keep
current` (or `Escape`) to leave your wallpaper untouched. Ticked images are
blacklisted either way. If left alone for 3 minutes it auto-applies the
first candidate, so a timer-triggered run never hangs behind the window.

### Cache

Downloaded wallpapers are cached under `~/Pictures/wallpapers/online/`
(newest 20 kept). `~/Pictures/wallpapers/log.txt` keeps a rolling history
(last 2000 lines).

## systemd units

`systemd/wallpaper.service` runs `wallpaper.sh --gui` once; `wallpaper.timer`
triggers it (30s after boot, then every `OnUnitActiveSec`, default 3h).
`install.sh` symlinks both into `~/.config/systemd/user/`. Adjust the
interval with `wallpaper.sh --interval <span>` rather than editing the timer
file directly — that writes a drop-in override so your change survives a
`git pull` of this repo.

## License

MIT, see [LICENSE](LICENSE).
