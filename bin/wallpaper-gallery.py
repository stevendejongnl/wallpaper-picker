#!/usr/bin/env python3
"""GTK3 gallery for wallpaper.sh.

Shows every downloaded/local wallpaper in a grid. Per wallpaper: set it,
remove it (delete only), or blacklist it (delete + never offered again).

All file listing / set / remove / blacklist logic lives in wallpaper.sh;
this script only shells out to it.

Usage: wallpaper-gallery.py /path/to/wallpaper.sh
"""
import os
import subprocess
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, Gtk  # noqa: E402

THUMB_SIZE = 200

if len(sys.argv) < 2:
    print("usage: wallpaper-gallery.py <path-to-wallpaper.sh>", file=sys.stderr)
    sys.exit(2)

SH_PATH = sys.argv[1]


def run_sh(args):
    return subprocess.run(["bash", SH_PATH] + args, capture_output=True, text=True)


def list_wallpapers():
    result = run_sh(["--list"])
    paths = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    paths = [p for p in paths if os.path.isfile(p)]
    paths.sort(key=os.path.getmtime, reverse=True)
    return paths


def current_wallpaper():
    result = run_sh(["--current"])
    path = result.stdout.strip()
    return path if path else None


def label_for(path):
    return os.path.splitext(os.path.basename(path))[0]


def show_preview(parent, path):
    display = Gdk.Display.get_default()
    parent_window = parent.get_window()
    monitor = (
        display.get_monitor_at_window(parent_window)
        if parent_window is not None
        else display.get_monitor(0)
    )
    geometry = monitor.get_geometry()
    width = int(geometry.width * 0.9)
    height = int(geometry.height * 0.9)

    popup = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
    popup.set_title(label_for(path))
    popup.set_transient_for(parent)
    popup.set_modal(True)
    popup.set_decorated(False)
    popup.set_position(Gtk.WindowPosition.NONE)
    popup.set_default_size(width, height)
    popup.move(
        geometry.x + (geometry.width - width) // 2,
        geometry.y + (geometry.height - height) // 2,
    )
    popup.connect(
        "key-press-event",
        lambda _w, e: popup.close() if (Gdk.keyval_name(e.keyval) or "") == "Escape" else None,
    )

    outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    popup.add(outer)

    header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
    header.set_border_width(6)
    name_label = Gtk.Label(label=label_for(path))
    name_label.set_halign(Gtk.Align.START)
    close_btn = Gtk.Button(label="Close")
    close_btn.connect("clicked", lambda _b: popup.close())
    header.pack_start(name_label, True, True, 0)
    header.pack_end(close_btn, False, False, 0)
    outer.pack_start(header, False, False, 0)

    image = Gtk.Image()
    try:
        pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(path, width, height - 50, True)
        image.set_from_pixbuf(pixbuf)
    except Exception:
        image = Gtk.Label(label="(failed to load image)")
    outer.pack_start(image, True, True, 0)

    popup.show_all()


class WallpaperGallery(Gtk.Window):
    def __init__(self):
        super().__init__(title="Wallpaper Gallery")
        self.set_default_size(900, 700)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_border_width(12)
        self.connect("key-press-event", self.on_key_press)

        self.current_path = current_wallpaper()

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.add(outer)

        self.status_label = Gtk.Label(label="")
        self.status_label.set_halign(Gtk.Align.START)
        outer.pack_start(self.status_label, False, False, 0)

        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        outer.pack_start(scroller, True, True, 0)

        self.flowbox = Gtk.FlowBox()
        self.flowbox.set_valign(Gtk.Align.START)
        self.flowbox.set_selection_mode(Gtk.SelectionMode.NONE)
        self.flowbox.set_homogeneous(True)
        self.flowbox.set_row_spacing(12)
        self.flowbox.set_column_spacing(12)
        scroller.add(self.flowbox)

        self.show_all()
        self.reload()

    def reload(self):
        for child in self.flowbox.get_children():
            self.flowbox.remove(child)

        paths = list_wallpapers()
        self.status_label.set_text(f"{len(paths)} wallpaper(s)")
        for path in paths:
            self.flowbox.add(self.make_tile(path))
        self.flowbox.show_all()

    def make_tile(self, path):
        col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        col.set_size_request(THUMB_SIZE, -1)

        image = Gtk.Image()
        try:
            pixbuf = GdkPixbuf.Pixbuf.new_from_file_at_scale(
                path, THUMB_SIZE, THUMB_SIZE, True
            )
            image.set_from_pixbuf(pixbuf)
        except Exception:
            image.set_from_icon_name("image-missing", Gtk.IconSize.DIALOG)
        event_box = Gtk.EventBox()
        event_box.add(image)
        event_box.connect("button-press-event", lambda _w, _e, p=path: show_preview(self, p))
        col.pack_start(event_box, False, False, 0)

        name = label_for(path)
        if path == self.current_path:
            name += "  (current)"
        name_label = Gtk.Label(label=name)
        name_label.set_line_wrap(True)
        name_label.set_max_width_chars(28)
        col.pack_start(name_label, False, False, 0)

        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=4)
        set_btn = Gtk.Button(label="Set")
        set_btn.connect("clicked", self.on_set, path)
        remove_btn = Gtk.Button(label="Remove")
        remove_btn.connect("clicked", self.on_remove, path)
        blacklist_btn = Gtk.Button(label="Blacklist")
        blacklist_btn.connect("clicked", self.on_blacklist, path)
        actions.pack_start(set_btn, True, True, 0)
        actions.pack_start(remove_btn, True, True, 0)
        actions.pack_start(blacklist_btn, True, True, 0)
        col.pack_start(actions, False, False, 0)

        return col

    def confirm(self, message):
        dialog = Gtk.MessageDialog(
            transient_for=self,
            modal=True,
            message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.OK_CANCEL,
            text=message,
        )
        response = dialog.run()
        dialog.destroy()
        return response == Gtk.ResponseType.OK

    def on_set(self, _button, path):
        run_sh(["--set", path])
        self.current_path = path
        self.reload()

    def on_remove(self, _button, path):
        if not self.confirm(f"Delete {os.path.basename(path)}?\nThis does not blacklist it -- it may be downloaded again."):
            return
        run_sh(["--remove", path])
        self.reload()

    def on_blacklist(self, _button, path):
        if not self.confirm(f"Blacklist {os.path.basename(path)}?\nThis deletes it and it will never be offered again."):
            return
        run_sh(["--blacklist", path])
        self.reload()

    def on_key_press(self, _widget, event):
        from gi.repository import Gdk

        name = Gdk.keyval_name(event.keyval) or ""
        if name == "Escape":
            self.close()
        return False


def main():
    win = WallpaperGallery()
    win.connect("destroy", Gtk.main_quit)
    Gtk.main()


if __name__ == "__main__":
    main()
