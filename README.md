# lumaloop

Subject-weighted auto exposure for a USB webcam on Linux, feeding a
v4l2loopback virtual camera that any video app can select.

The name is the mechanism: a closed loop on measured luma. It works with any
UVC webcam that exposes the standard `exposure_time_absolute` and `gain`
controls.

## The problem

Webcams meter the whole frame. Sit with a window behind you and the camera
exposes for the window — your face goes dark. Sit in a dark room with a lamp
on you and it does the opposite, hunting brightness until your face blows out.
Most cameras offer no exposure-compensation control to bias this, and their
auto-exposure cannot be told what part of the frame you care about.

So this takes exposure away from the camera. It meters a box where a seated
person actually is, drives the camera's manual exposure and gain to keep the
subject at a target brightness, and holds a separate ceiling so highlights
never clip in the process.

```
 /dev/videoN --ffmpeg--+--> /dev/videoM (v4l2loopback) --> your video app
                       |
                       +--> 192x108 frames on a pipe --> the metering loop,
                       |    which drives MANUAL exposure/gain over V4L2
                       |
                       +--> a JPEG snapshot every few seconds
```

It also ships a small status window, because once a video app holds the
virtual camera nothing else can stream it — the snapshot is the only way to
see what is actually going out.

## Requirements

| | |
|---|---|
| Linux with V4L2 | any modern distro |
| `ffmpeg` | capture, format conversion, output |
| `v4l2-ctl` | from `v4l-utils`; reads and writes camera controls |
| `v4l2loopback` | the virtual camera device |
| Python 3.11+ | stdlib only for the pipeline (`tomllib` for config) |
| PySide6 | only for the optional status window |

    # Fedora
    sudo dnf install ffmpeg v4l-utils v4l2loopback python3-pyside6

    # Debian / Ubuntu
    sudo apt install ffmpeg v4l-utils v4l2loopback-dkms python3-pyside6

    # Arch
    sudo pacman -S ffmpeg v4l-utils v4l2loopback-dkms pyside6

### The virtual camera

Load the module, giving it a label your video app will show:

    sudo modprobe v4l2loopback exclusive_caps=1 card_label="Virtual Camera"

`exclusive_caps=1` matters: without it some apps (Chrome, Firefox) refuse to
list the device. To make it persistent:

    # /etc/modules-load.d/v4l2loopback.conf
    v4l2loopback

    # /etc/modprobe.d/v4l2loopback.conf
    options v4l2loopback exclusive_caps=1 card_label="Virtual Camera"

If you already run OBS's virtual camera, that device works too — point
`vcam_name` at its label instead.

## Install

    git clone <this repo> && cd lumaloop
    ./install.sh

That symlinks `lumaloop` and `lumaloop-app` into `~/.local/bin`, the systemd
unit into `~/.config/systemd/user`, generates the desktop entry, and seeds
`~/.config/lumaloop/config.toml`. Nothing needs root, and nothing is copied —
`git pull` updates what is installed. `./install.sh --uninstall` removes the
links and leaves your config alone.

## Configure

Find your camera:

    lumaloop --list-devices

    /dev/video0    Virtual Camera                    loopback
    /dev/video1    Integrated Camera                 capture
    /dev/video3    Logitech BRIO                     capture

    Stable names that survive a replug:
      /dev/v4l/by-id/usb-046d_Logitech_BRIO_XXXXXXXX-video-index0

Then edit `~/.config/lumaloop/config.toml`. Everything is optional — keys you
leave out keep their defaults:

```toml
[camera]
camera_by_id = "/dev/v4l/by-id/usb-046d_Logitech_BRIO_*-video-index0"

[exposure]
target = 132        # raise for a brighter subject
```

**Use `camera_by_id`, not `/dev/videoN`**, if you have more than one camera:
device numbers shift when things are replugged or modules load in a different
order, and a laptop's internal camera usually enumerates first. The glob keeps
working across replugs; leaving the serial as `*` keeps it working across
cameras of the same model.

`config.example.toml` documents every setting with its default and the reason
it is set that way. `lumaloop --show-config` shows what is actually in effect
and marks what your config changed.

## Run

    systemctl --user daemon-reload
    systemctl --user enable --now lumaloop.service

Then pick your virtual camera's label in Zoom, Meet, Discord, OBS, whatever.
To watch it work: `journalctl --user -u lumaloop -f`, or run `lumaloop`
directly in a terminal.

The unit deliberately sets `StartLimitIntervalSec=0`. The camera is often
unplugged at boot and plugged in later, the script exits in well under a
second when it cannot find one, and any burst limit turns those fast exits
into a permanently `failed` unit that never retries.

## The status window

`lumaloop-app` (also in your application menu as **Webcam**) shows the live
snapshot, translates the metering log into plain language, and starts or stops
the unit. Its Start button always runs `systemctl --user reset-failed` first,
so it recovers a wedged unit in one click.

    last frame  0.7s ago  ·  every 5.0s  ·  4 frames
    Brightness    on target
    Highlights    not clipping
    Exposure      82

The line under the preview is deliberate: a still room looks identical whether
the picture is live or frozen, so the window counts frames rather than asking
you to trust it. The preview cannot update faster than `snapshot_secs`.

The dashed box on the preview is the metering box. Its label shows the
subject level against the target and the highlight level against the ceiling,
from the last metering line the pipeline logged. While the loop is holding
steady it logs only every `heartbeat_s`, so those numbers can lag a still
picture by that much.

**Target** sets how bright the loop keeps you. It applies to the running
pipeline within a couple of seconds, with no restart, and is remembered across
restarts. The window stores it in `~/.local/state/lumaloop/target`, which
takes precedence over `target` in your config. **Reset** removes that file and
returns to the configured value.

## How the loop works

Two constraints, one controller:

1. keep the subject near `target` — the 70th percentile of a metering box
2. keep highlights off a ceiling — the 99th percentile of the same box

They disagree in a dark room with a lit subject, so the ceiling **vetoes**
brightening and forces darkening when exceeded. "Highlights fine and below
target" is a legal resting state; that is what stops it hunting between the
two objectives.

Percentiles over a wide box, rather than a mean over a face box, because a
face box goes stale the moment you shift in your seat and then meters the wall.
Exposure is spent before gain, since gain is amplification rather than light.
Darkening is rate-limited faster than brightening, because being blown out is
worse than being briefly dim.

In control terms it is a **P controller in velocity form**, wrapped in
selector and split-range logic:

- **P, on relative error.** The correction is `1 + K·err/level`. The plant is
  multiplicative — doubling exposure roughly doubles luma — so working in
  ratio space linearizes it and one gain holds across the whole range.
- **No I term**, because the actuator is already an integrator: each step
  *scales* the current exposure instead of setting an absolute one, which is a
  discrete integrator on log-exposure. Adding a literal integral on top would
  double-integrate and oscillate.
- **No D term.** The metering stream is 1fps and noisy, where a derivative is
  a noise amplifier. Its jobs are done structurally instead: a median over
  three samples, a latency gate that discards frames predating the last
  correction (the camera takes about a frame to respond), a deadband against
  dithering on a quantized actuator, and asymmetric slew limits.
- **Selector and split-range.** The highlight ceiling is an override that
  vetoes the setpoint, not a second loop; exposure and gain are one actuator
  used in priority order. `subject_floor` is anti-windup against a constraint
  that physically cannot be met.

The source comments explain each constant and, more usefully, what went wrong
before it was set that way. They are worth reading before you retune anything.

## Troubleshooting

**`camera not found`** — `lumaloop --list-devices`, then set `camera_by_id`
or `camera_name`. With nothing configured it takes the first capture device,
which on a laptop is usually the internal camera.

**`ffmpeg failed to start - camera in use?`** — something else holds the
camera. Close OBS, browser tabs with camera permission, or a stray `ffmpeg`.

**The unit is `failed` and will not restart** — `systemctl --user reset-failed
lumaloop.service && systemctl --user start lumaloop.service`, or click Start in
the window. If you hit this repeatedly, check your unit has
`StartLimitIntervalSec=0`.

**Highlights still clip** — lower `high_max`. If the sun is directly on you the
loop will report `floored: highlights unreachable (sun?)` and hold: at that
point the highlights are gone whatever it does, and darkening further only
crushes the rest of the frame.

**The picture is noisy** — gain is doing the work because exposure is maxed at
`exp_max` (320 ≈ 1/31s, the limit at 30fps). Lower `gain_max` to trade
brightness for cleanliness, or add light.

**The preview does not update** — it cannot be fresher than `snapshot_secs`.
The counter under the preview tells you the measured interval.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).

`ffmpeg` and `v4l2-ctl` are invoked as separate processes, and PySide6 is used
under the LGPL, so neither constrains this choice; the copyleft is deliberate.
