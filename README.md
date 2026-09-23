# Lenovo LOQ Fan Control for Linux

Fan control for the Lenovo LOQ 15IAX9 (machine type 83GS, BIOS NECN47WW) on Linux.

The installer configures Lenovo's `lenovo_wmi_other` kernel interface, installs a small command-line controller, and listens for the laptop's Copilot key. Pressing the key cycles through automatic, low, medium, maximum, and automatic fan control. A systemd timer checks temperatures while a manual profile is active and returns control to the firmware at 85 °C.

> **Hardware scope:** The calibration in this project is for the exact Lenovo LOQ 15IAX9 / 83GS / NECN47WW combination. Both the installer and the installed controller check this combination. `--force-unsupported` bypasses only the installer's hardware check; the controller still refuses fan-mode changes on other models or BIOS versions.

## Compatibility with other Lenovo LOQ laptops

This version supports only Lenovo LOQ 15IAX9, machine type `83GS`, with BIOS `NECN47WW`. Even a different BIOS version on the same model is rejected by the current checks.

Other LOQ models may be candidates for future support, but compatibility is not established by sharing the LOQ name. Support requires checking the model's `lenovo_wmi_other` interface, two writable fan targets, firmware behavior, and model-specific fan calibration, then validating automatic control and the temperature fallback on that hardware. The current raw fan values and approximate RPM figures must not be assumed to apply to other models.

`--force-unsupported` does not enable support for another laptop: it skips the installer's DMI/BIOS check but does not bypass the installed controller's independent check.

## Features

- Calibrated dual-fan profiles: approximately 900, 2,900, and 5,800 RPM.
- Copilot-key profile cycling with desktop notifications.
- Automatic temperature safety fallback at 85 °C.
- `status`, `uninstall`, and self-test commands.
- Package detection and installation through `pacman` on Arch-based systems.
- Sudoers entry limited to the fan-control commands; no unrestricted passwordless root shell is created.

## Requirements

- Lenovo LOQ 15IAX9, machine type `83GS`, BIOS `NECN47WW`.
- Linux kernel 7.2.2 or newer (the installer checks the running kernel).
- A systemd-based Arch Linux installation with `pacman` (CachyOS is the original target).
- Root access through `sudo` or `pkexec`.
- A graphical session for desktop notifications.

The installer checks for `bash`, `python3`, `notify-send`, `flock`, `runuser`, `modprobe`, `systemctl`, and `visudo`. Missing packages are offered through the configured `pacman` repositories.

## Installation

Clone or download this repository, then run:

```bash
chmod +x loq-fan-control-installer.sh
./loq-fan-control-installer.sh --install
```

The installer will ask for the desktop username when it cannot infer it from `sudo`. It installs the controller under `/usr/local/sbin`, systemd units under `/etc/systemd/system`, the kernel-module configuration under `/etc/modprobe.d`, and a restricted sudoers rule under `/etc/sudoers.d`.

The installer runs a short self-test by default. The maximum profile is audible for a few seconds. Skip it with:

```bash
./loq-fan-control-installer.sh --skip-self-test
```

If the kernel module cannot be reloaded safely while the system is running, reboot once and check the result with `--status`.

## Using the controller

After installation, press the laptop's **Copilot key** to cycle through:

`Automatic → Low (≈900 RPM) → Medium (≈2,900 RPM) → Maximum (≈5,800 RPM) → Automatic`

Each change produces a desktop notification. The currently selected mode is stored only in `/run` and therefore resets to firmware automatic control after a reboot.

The installed command can also be used directly:

```bash
sudo /usr/local/sbin/loq-fan-control status
sudo /usr/local/sbin/loq-fan-control low
sudo /usr/local/sbin/loq-fan-control medium
sudo /usr/local/sbin/loq-fan-control max
sudo /usr/local/sbin/loq-fan-control auto
sudo /usr/local/sbin/loq-fan-control cycle
```

The installer adds a narrow sudoers rule so these commands can be run without a password by the detected desktop user. The Copilot listener itself runs as a system service and invokes only the controller.

## Safety behavior

Manual profiles are not a replacement for the laptop's firmware protections. A timer runs every five seconds while the service is enabled. It reads available hwmon temperatures and NVIDIA GPU temperature (when `nvidia-smi` is available); at or above 85 °C it switches back to `auto` and logs the event with tag `loq-fan-control`.

Use the firmware-controlled profile for normal operation. Fan targets are raw firmware values calibrated on the supported model, so the RPM values are approximate rather than guarantees.

## Status and troubleshooting

```bash
./loq-fan-control-installer.sh --status
systemctl status loq-copilot-fan.service
systemctl status loq-fan-safety.timer
journalctl -u loq-copilot-fan.service
journalctl -t loq-fan-control
```

Common causes of a failed installation are an unsupported model or BIOS, a kernel older than 7.2.2, a missing `lenovo_wmi_other` interface, or a missing graphical session for notifications. `--force-unsupported` bypasses only the installer's DMI/BIOS check; it does not bypass the installed controller's model/BIOS check, kernel checks, or fan-interface checks.

## Uninstallation

```bash
./loq-fan-control-installer.sh --uninstall
```

Uninstallation first requests automatic fan control, stops and disables the services, removes installed files and the sudoers rule, and reloads systemd. Reboot afterward if you want the module parameters to be fully reset.

## Project layout

| File | Purpose |
| --- | --- |
| `loq-fan-control-installer.sh` | Privileged installer, updater, status command, and uninstaller. |
| `/usr/local/sbin/loq-fan-control` | Installed fan profile controller. |
| `/usr/local/sbin/loq-copilot-listener` | Installed Copilot-key listener. |
| `loq-copilot-fan.service` | Keeps the key listener running. |
| `loq-fan-safety.timer` | Runs the temperature safety check every five seconds. |

## Disclaimer

This is an enthusiast project that writes calibrated values to a vendor-specific kernel interface. Test it on your own hardware and keep the firmware automatic profile available. The author is not responsible for hardware damage, data loss, or unsupported configurations.

## License

This project is released under the MIT License. See [LICENSE](LICENSE).
