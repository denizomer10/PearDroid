# PearDroid runtime design (headless Android)

This document describes the intended architecture for the part of PearDroid that
is **not yet implemented**: running Android userspace headless on macOS and
bridging only the launched app's surface into the native SwiftUI shell.

---

## Approach: Hypervisor.framework + a minimal *virtual* kernel

After testing both hypervisor APIs on an Apple M1, the runtime is built on
**Hypervisor.framework** (the raw `hv_*` API), the same foundation OrbStack uses:

- Its entitlement, `com.apple.security.hypervisor`, **is honoured for an ad-hoc
  signed build** — verified: `hv_vm_create`, `hv_vcpu_create`, `hv_vm_map` and
  `hv_vcpu_run` all return `HV_SUCCESS`, and a hand-written guest program
  (`movz x0,#42; hvc #0`) executed and trapped back with `x0 = 42`.
- By contrast, `Virtualization.framework` needs `com.apple.security.virtualization`,
  which the OS refuses for ad-hoc signatures (see below). That is why it is not used.
- Apple also ships **GICv3 emulation** in Hypervisor.framework (`hv_gic_create`,
  `hv_gic_set_spi`, MSI, distributor register access — macOS 15+). The single
  hardest part of a VMM is therefore provided by the OS.

### On the kernel: do **not** use the Asahi kernel

Asahi Linux is a port of Linux to Apple silicon **bare metal**; its drivers
(DCP, Apple GPU, NVMe, USB, PCIe …) talk to *physical Apple hardware* that does
not exist inside a guest. Using it would make the guest kernel **larger and less
minimal**, not more.

A guest under our VMM wants the opposite: a small, **virtualised** arm64 kernel
with virtio drivers, GIC, architected timer, PSCI and a serial console. Any
generic `linux-virt` kernel has all of that (e.g. Alpine's `vmlinuz-virt`, which
we already use). Moving from that to Android userspace needs no Apple drivers at
all — only the binder options Waydroid relies on:

```
CONFIG_ANDROID_BINDER_IPC=y
CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"
```

### VMM progress (verified)

`tools/vmm` implements the device-model core and runs it end-to-end:

```
PearDroid VMM starting
loaded 81 guest instructions at 0x40080000
uart> PearDroid VMM: guest code is running.
PSCI: power off requested
```

The guest wrote a string through an **emulated PL011 UART** (decoded from an
MMIO data-abort fault: ESR `ISV/SAS/SRT/WnR`, faulting IPA, register transfer,
PC advance) and then powered off via **PSCI/HVC**. That is exactly the mechanism
Linux needs for its early console.

### What a Linux boot still needs

1. **A directly-bootable kernel image.** Distro `vmlinuz` files are usually
   **EFI** images (PE/COFF, entry via the PE entry point) or **EFI zboot**
   (a compressed payload behind an EFI stub) — Alpine's `vmlinuz-virt` is the
   latter: it starts with `MZ` and has no arm64 `Image` header at offset 0, so it
   cannot be entered at `code0`. A kernel built with `make Image` for direct boot
   (what Buildroot's `qemu_aarch64_virt_defconfig` produces) *is* enterable at its
   base. This is what the first real boot attempt waits on.
2. **Device tree (DTB)** describing memory, CPUs, GIC, timer and the UART
   — implemented in `tools/vmmboot` (hand-built FDT).
3. **GIC + timer**: `hv_gic_create` works (`distributor_size` /
   `redistributor_region_size` are queried and put in the DTB); still to do is
   turning `HV_EXIT_REASON_VTIMER_ACTIVATED` into a guest PPI.
4. **PSCI** beyond SYSTEM_OFF (CPU_ON for secondary cores).
5. Swap the PL011 for / add **virtio-console** and, later, virtio-blk/net.

### Building a minimal kernel/rootfs (Buildroot in a container)

Buildroot needs a Linux build host. On this machine that is a container under
**OrbStack** (`~/.orbstack/bin/docker`, aarch64, native builds):

```sh
docker run -d --name peardroid-br -v <out>:/out debian:stable bash -lc '\
  apt-get install -y build-essential git wget cpio unzip rsync bc python3 file \
    ca-certificates libncurses-dev; \
  git clone --depth 1 https://github.com/buildroot/buildroot.git /br; cd /br; \
  make qemu_aarch64_virt_defconfig; \
  printf "\nBR2_PRIMARY_SITE=\"https://sources.buildroot.net/\"\n" >> .config; \
  make olddefconfig; make -j8; \
  cp output/images/Image output/images/rootfs.cpio* /out/'
```

Note: set `BR2_PRIMARY_SITE` to Buildroot's official mirror — the per-package
default mirrors are sometimes broken (one caused a long retry loop here).

---

## Verified findings (what we actually learned on this machine)

A boot harness now lives in `tools/vmprobe` (Swift, links
`Virtualization.framework`). What it established, on an Apple M1 running macOS:

1. **The framework is usable in principle.** `VZVirtualMachineConfiguration.validate()`
   passes once the process carries `com.apple.security.virtualization`, and the
   system spawns the `com.apple.Virtualization.VirtualMachine` XPC service.
2. **Every `VZVirtualMachine` call must be made on the queue the machine was
   created with.** Calling `start()` from the main thread trips a libdispatch
   assertion (`Block was expected to execute on queue …`) and aborts the process.
   The harness now dispatches `start()` onto that queue.
3. **Ad-hoc signing is not enough.** With `codesign -s -` + the entitlement, the
   boot fails with `VZErrorDomain code 1 “Internal Virtualization error”`, and the
   system log shows the reason:
   ```
   AMFI: 'VMProbe' is adhoc signed.
   amfid: not valid: “The file is adhoc signed or signed by an unknown certificate chain”
   AMFI: code signature validation failed.
   ```
   The restricted entitlement is only honoured for a **trusted signature**. A
   build with no code-signing identity (as on this machine: `0 valid identities`)
   therefore cannot start a guest. This is the current hard blocker.

### To unblock

- Sign `PearDroid.app` with a real **code-signing identity** that is allowed to
  use the virtualization entitlement (Apple Developer team; in Xcode, select the
  team so a provisioning profile is generated). Then `tools/vmprobe` should boot
  the Alpine kernel/initramfs.
- Quick check once signed:
  ```sh
  codesign -d --entitlements - build/PearDroid.app   # must list virtualization
  build/PearDroid.app/Contents/MacOS/PearDroid        # runtime chip should read “ready”
  ```

`tools/vmprobe` also needs a kernel + initramfs. Alpine `netboot` for aarch64
works as a minimal guest:

```
https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/netboot/vmlinuz-virt
https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/netboot/initramfs-virt
```

---

## Goal

```
┌──────────────────────────── macOS host ────────────────────────────┐
│  SwiftUI launcher  ──launch──▶  Surface host (CAMetalLayer)         │
│         ▲                              ▲                            │
│         │ status / IPC                 │ frames (IOSurface/MTLTexture)
│  ┌──────┴──────────────────────────────┴───────────────────────┐   │
│  │ Virtualization.framework  ── Linux guest ── Android user-    │   │
│  │                                            space (headless)  │   │
│  │   Waydroid-style: LXC container + binder + minimal surface   │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

Key idea: **Android never draws a UI**. There is no SystemUI and no home screen.
The only surface that exists is the launched app's, and its frames are handed to
the host, which presents them in a `CAMetalLayer` — the same layer the proof of
concept already renders Vulkan into.

---

## Why not "just build AOSP"

Booting AOSP directly on Apple silicon is not practical:

- AOSP expects Linux: `binder`, `ashmem`/`memfd`, a Linux kernel with the right
  config, `libc` (bionic) user space, and a HAL largely written for Linux.
- A full AOSP checkout + build is on the order of hundreds of GB and hours of
  compute, and produces images for real devices or emulators — not for a
  `Virtualization.framework` guest out of the box.
- Even a minimal headless build must keep SurfaceFlinger, the graphics/allocator
  HALs, and the input HALs alive, and it must be told to run without SystemUI.

The pragmatic path is therefore a **Linux VM + an Android-compatibility
container**, which is exactly the Waydroid model on Linux, re-hosted on macOS.

---

## Components

### 1. Linux guest (Virtualization.framework)
- `VZVirtualMachine` running an arm64 Linux kernel + rootfs (Ubuntu/Debian).
- Boot a minimal userland; no desktop, no display server.
- Requires the app to be signed with the
  `com.apple.security.virtualization` entitlement.

**Needed artifacts (not in this repo):** an arm64 Linux kernel (`vmlinuz`) and a
rootfs image, plus a `VZVirtualMachineConfiguration` describing CPU/memory/disk
and a virtio network device.

### 2. Android compatibility container (in the guest)
- Waydroid-style: an LXC container running the Android runtime.
- Needs `binder`/`binderfs`, `ashmem`/`memfd`, and the Android system + vendor
  images for arm64.
- Started headless: no `SystemUI`, no `Launcher3`, session type forced minimal.

### 3. Surface bridge (guest ➜ host)
This replaces the demo triangle.
- The guest's graphics HAL is pointed at a **shared buffer** rather than a real
  display: either an `IOSurface`-backed virtio-gpu resource, or a
  `VkExtramemoryMetal`/`MTLTexture` shared across the VM boundary.
- On the host, `VulkanRenderer` (or a `Metal` path) samples/copies that buffer
  into the swapchain image instead of clearing and drawing a triangle.
- Start simplest: a system-memory framebuffer for the app's window, uploaded to a
  `MTLTexture` each frame. Optimise later with `IOSurface` / zero-copy.

### 4. Input bridge (host ➜ guest)
- Keyboard/mouse/touch events from the SwiftUI surface are encoded and injected
  into the guest's input HAL (evdev/uinput over virtio-input, or a Wayland-style
  protocol if the container uses one).

### 5. Control channel
- A small IPC channel (vsock or a virtio serial port) carries:
  `install(apk)`, `launch(package)`, `stop()`, `status`, and app lifecycle
  events back to the launcher.

---

## Launcher integration

`AppLibrary` already models the pieces this needs:

- `AppLibrary.apps` — installed packages (today: scanned APKs; later: APKs
  installed into the container).
- `AppLibrary.launch(_:)` — today it swaps the SwiftUI view to
  `GameSurfaceView`; later it also sends `launch(package)` over the control
  channel.
- `GameSurfaceView` — already presents a `CAMetalLayer`; it only needs its
  contents to come from the guest instead of the triangle.

So the launcher and the surface plumbing are done; what remains is the runtime
on the other side of that seam.

---

## Suggested build order

1. **Linux guest skeleton** — boot arm64 Linux under `Virtualization.framework`,
   log to a file, prove SSH/serial access.
2. **Container** — run the Android container headless, prove `am start` of a
   trivial app works over the control channel.
3. **Framebuffer transfer** — capture the app's window in the guest and blit it
   into the host `MTLTexture`. This is the moment "the game appears".
4. **Input** — inject events; verify a tap lands where it should.
5. **Packaging** — install APKs from the launcher rather than a host folder.

Steps 1–2 are infrastructure. Step 3 is the interesting one and is where the
existing MoltenVK/Metal layer pays off.

---

## Constraints to keep in mind

- **Virtualization entitlement & signing.** A sandboxed/notarised app needs the
  virtualization entitlement; an unsigned local build may still run but is not
  shippable.
- **Performance.** `Virtualization.framework` on Apple silicon is fast, but
  graphics go through an extra copy unless you get to a shared/IOSurface path.
  Getting the surface bridge right is what determines whether this feels
  "near-native".
- **Anti-cheat is out of scope.** Many games will refuse to run in a
  virtualized/translated environment. That is their policy and this project does
  not attempt to defeat it.
