# Jellyfin libkrun External-Kernel Prototype

This directory builds a disposable Fedora image for one question: does a
Linux 6.18 guest kernel allow libkrun's Intel DRM native context to expose
useful VA-API decode or encode capabilities?

It is not a Jellyfin production image. It mounts no NAS storage and contains
no service configuration.

## Build

```bash
podman build \
  --file containers/jellyfin-krun-kernel-prototype/Containerfile \
  --tag localhost/jellyfin-krun-kernel-prototype:6.18.42 \
  containers/jellyfin-krun-kernel-prototype
```

Or build and export a portable OCI archive in one step:

```bash
containers/jellyfin-krun-kernel-prototype/build-and-export.sh
```

The default archive path is
`/tmp/jellyfin-krun-kernel-prototype-6.18.42.oci.tar`. Copy that archive and
`run-on-nas.sh` to `/var/tmp` on the NAS with:

```bash
containers/jellyfin-krun-kernel-prototype/copy-to-nas.sh
```

This transfers files only and runs no remote command. After reviewing the
runner, run this yourself on the NAS:

```bash
sudo /var/tmp/run-on-nas.sh
```

The NAS script imports an image into `_nas_jellyfin`'s rootless image store,
which is its only persistent change. It leaves production Jellyfin running,
mounts no application or media data, applies a three-minute timeout, and runs
passt inside a temporary host network namespace.

## Runtime contract

The host needs crun-krun/libkrun with GPU support, virglrenderer, passt, KVM,
and `/dev/dri/renderD128`. Run the image rootlessly under the Jellyfin service
identity with:

```bash
podman run --rm \
  --runtime=krun \
  --device=/dev/dri/renderD128:/dev/dri/renderD128 \
  --annotation=krun.cpus=2 \
  --annotation=krun.ram_mib=2048 \
  --annotation=krun.gpu_flags=1411 \
  --annotation=krun.use_passt=1 \
  localhost/jellyfin-krun-kernel-prototype:6.18.42
```

crun 1.28 checks for `/usr/libexec/virgl_render_server` even though native
context mask `1411` does not enable the render-server bit. The image installs
the real Fedora package to satisfy that check.

Success requires at least one `VLD`, `EncSlice`, or `EncSliceLP` VA-API
entrypoint. Driver initialization or `VideoProc` alone does not pass.

The passt experiment is only a way to give the stock external kernel standard
virtio-net. It does not approve crun 1.28's broad all-port mapping for
production. `run-on-nas.sh` contains that behavior inside a temporary host
network namespace. libkrun supports gvproxy, but crun 1.28 does not expose or
manage that backend through its krun annotations; using it for a real Quadlet
would require extending the crun krun handler or owning a separate launcher.
