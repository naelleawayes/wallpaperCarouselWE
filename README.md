# Wallpaper Carousel WE

##This is a fork of [WallpaperCarousel](https://github.com/motor-dev/wallpaperCarousel) by motor-dev.
### ⚠️ I don't know sh*t about QML and this was written by Claude with a little bit of review on my part, but i cannot guarantee best practices are followed both for QML and for the DMS plugin implementation. I will eventually learn how to do this properly myself but i just wanted a quick fix for now, for my personal usage only. Use with caution. ⚠️

#### What changes from the original plugin

Does away with DMS' built in Wallpaper manager.
Uses swww for gifs/images, and linux-wallpaperengine for WE scenes.
Adds a settings panel to pick additional folders for wallpapers (untested), to change animation duration and FPS, and to pick an animation type.
Keeps matugen dynamic theming and enables that feature for WE as well.


### Original Readme:

Based on the original wallpaper picker by [ilyamiro](https://github.com/ilyamiro/nixos-configuration).

A [DankMaterialShell](https://danklinux.com/) plugin that lets you browse and pick wallpapers from a fullscreen skewed carousel overlay.

![screenshot](screenshot.png)

## About

Wallpaper Carousel scans your current wallpaper directory and displays all images in an animated 3D-skewed carousel. Navigate with keyboard or mouse, press Enter to apply. Thumbnails are pre-cached in memory at boot for instant opening.

This plugin integrates with all DMS features — selecting a wallpaper updates the shell wallpaper, color scheme, and any other DMS components that react to wallpaper changes.


https://github.com/user-attachments/assets/39bcde76-7d7b-40c0-a083-3b8961edf10b

## Credits

Original wallpaper picker by [ilyamiro](https://github.com/ilyamiro/nixos-configuration).

Wallpaper collection in the screenshot/video from [Andreas Rocha](https://www.andreasrocha.com/)


## Install

> **Note:** DankMaterialShell must be managing your wallpaper for this plugin to work. It does not work with external wallpaper engines (e.g. swww, swaybg, hyprpaper). Enable wallpaper management in DMS Settings → Wallpaper.

1. Download the latest archive from the [Releases](../../releases) page
2. Extract it into your DMS plugins directory:
   ```sh
   tar xf wallpaperCarousel-*.tar.gz -C "${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins/"
   ```
3. Open DankMaterialShell Settings → Plugins and enable **Wallpaper Carousel**
4. Bind keys in your compositor config (see below) or call the IPC commands from a script

## IPC Commands

Control the carousel via DMS IPC:

| Command | Description |
|---------|-------------|
| `dms ipc wallpaperCarousel toggle` | Open or close the overlay |
| `dms ipc wallpaperCarousel open` | Open the overlay |
| `dms ipc wallpaperCarousel close` | Close the overlay |
| `dms ipc wallpaperCarousel cycleNext` | Open (if closed) and highlight next wallpaper |
| `dms ipc wallpaperCarousel cyclePrevious` | Open (if closed) and highlight previous wallpaper |

**Keyboard shortcuts** (when open): `←` / `→` to navigate, `Enter` to apply, `Escape` to close.

## Example Compositor Keybindings

### Niri

In `~/.config/niri/config.kdl`:

```kdl
binds {
    Mod+W { spawn "dms" "ipc" "wallpaperCarousel" "toggle"; }
    Mod+Shift+Right { spawn "dms" "ipc" "wallpaperCarousel" "cycleNext"; }
    Mod+Shift+Left { spawn "dms" "ipc" "wallpaperCarousel" "cyclePrevious"; }
}
```

### Hyprland

In `~/.config/hypr/hyprland.conf`:

```ini
bind = SUPER, W, exec, dms ipc wallpaperCarousel toggle
bind = SUPER SHIFT, Right, exec, dms ipc wallpaperCarousel cycleNext
bind = SUPER SHIFT, Left, exec, dms ipc wallpaperCarousel cyclePrevious
```
