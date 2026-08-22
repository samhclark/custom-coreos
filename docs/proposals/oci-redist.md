# OCI Redistribution Repository

Status: planning document

This document records the proposed naming, provenance, metadata, SBOM, and
signature policy for `ghcr.io/samhclark/oci-redist/*`.

The repository publishes two kinds of image:

1. exact upstream mirrors, primarily to reduce dependence on an unreliable
   source registry; and
2. maintained derivative images that preserve upstream application lineage
   while changing the OCI image, runtime contract, or application contents.

The repository name is intentionally `oci-redist`. It covers both exact
redistribution and derived images without implying that every image is built
from source.

## Naming scheme

The image repository name communicates the compatibility boundary:

```text
<name>          exact upstream mirror
<name>-repack   any maintained derivative of upstream software
```

`-repack` is deliberately broad. It applies when the derivative changes any
of the following:

- base image or operating-system userspace;
- filesystem layout or included utilities;
- default user, UID/GID behavior, or permissions;
- entrypoint, init behavior, healthcheck, or signal handling;
- bundled configuration or assets;
- compiled plugins or modules;
- patches to the upstream application;
- build flags or other application behavior.

The name must not try to enumerate every modification. A Caddy image with the
Cloudflare DNS module and a DNS-related patch is therefore:

```text
ghcr.io/samhclark/oci-redist/caddy-repack
```

It is not `caddy-cloudflare`, `lab-caddy`, or another feature-specific name.
Future modifications remain part of the same maintained derivative and are
recorded in the build metadata, SBOM, provenance attestation, and release
notes.

Examples:

```text
ghcr.io/samhclark/oci-redist/fedora-coreos
ghcr.io/samhclark/oci-redist/jellyfin
ghcr.io/samhclark/oci-redist/sonarr-repack
ghcr.io/samhclark/oci-redist/radarr-repack
ghcr.io/samhclark/oci-redist/prowlarr-repack
ghcr.io/samhclark/oci-redist/sabnzbd-repack
ghcr.io/samhclark/oci-redist/caddy-repack
```

Locally authored companion software such as `jellyfin-exporter` is out of
scope. It belongs in the repository that owns the software or in a separate
application repository, not in `oci-redist` merely because Custom CoreOS uses
it.

## Compatibility promises

The image name defines the minimum promise:

| Name form | Promise | What it does not promise |
| --- | --- | --- |
| `<name>` | The published image is a digest-preserving mirror of the upstream image. | Availability of the upstream project, or that the upstream image itself is safe. |
| `<name>-repack` | The image has identifiable upstream application lineage and a documented derivative contract. | Drop-in compatibility with the upstream OCI image. |

Application compatibility and image compatibility are separate claims. For
example, a minimal `sonarr-repack` can preserve Sonarr's application behavior
while intentionally changing `/config`, the entrypoint, the default user, or
the available shell utilities. It must not be advertised as a drop-in
replacement for the LinuxServer.io Sonarr image unless those image-level
contracts have actually been preserved and tested.

## Initial image inventory

The current NAS repository contains the following runtime image groups:

### Exact mirrors

These currently use upstream images without rebuilding the image contents:

```text
alertmanager
blackbox-exporter
garage
grafana
immich-machine-learning
immich-server
jellyfin
valkey
victoria-metrics
vmalert
```

Immich PostgreSQL is also a mirror if its identity adapter remains outside the
image. If the adapter is baked into a new image, publish it as:

```text
immich-postgres-repack
```

### Repack images

The four media-automation images currently need image-specific entrypoint and
identity handling. If they are rebuilt as minimal or otherwise repository-
owned images, use:

```text
sonarr-repack
radarr-repack
prowlarr-repack
sabnzbd-repack
```

Caddy is also a repack image because it contains compiled application changes:

```text
caddy-repack
```

The feature details belong in provenance and release metadata, not the image
repository name.

The build-only Fedora, SOPS, Butane, and ShellCheck images are tooling inputs,
not application products. They may be mirrored for build reliability later,
but should not be confused with the runtime image catalog. The
`fedora-zfs-kmods` images remain outputs of their separate project.

## Tags and digests

All deployment references should use a digest:

```text
ghcr.io/samhclark/oci-redist/caddy-repack:2.11.4-redist.1@sha256:<digest>
```

Tags are human-facing release aliases. They are not immutable identities.

### Mirrors

Preserve the upstream tag where practical:

```text
fedora-coreos:stable
jellyfin:10.11.11
```

The mirror pipeline should copy the complete multi-platform manifest and all
layers without modifying the image config or manifest. If the copied image
has the same content digest as upstream, it remains an exact mirror.

### Repack images

Do not reuse the upstream tag as though the image were upstream. Include a
repository-owned revision:

```text
sonarr-repack:4.0.19.2979-redist.1
radarr-repack:6.3.0.10514-redist.1
caddy-repack:2.11.4-redist.1
```

The `redist.N` revision changes whenever the image build, base image, patch,
plugin, entrypoint, or other published image contents change. The upstream
source version and exact input digest are recorded separately.

## OCI metadata

OCI annotations are string-to-string metadata and should use reverse-domain
namespacing. The `org.opencontainers.image.*` namespace is reserved for OCI's
standard annotations. Repository-specific keys use:

```text
com.samhclark.oci-redist.*
```

Do not use `io.samhclark.*`.

### Standard OCI annotations

Use the standard annotations where they fit:

```text
org.opencontainers.image.created
org.opencontainers.image.title
org.opencontainers.image.description
org.opencontainers.image.version
org.opencontainers.image.revision
org.opencontainers.image.source
org.opencontainers.image.documentation
org.opencontainers.image.url
org.opencontainers.image.vendor
org.opencontainers.image.licenses
org.opencontainers.image.base.name
org.opencontainers.image.base.digest
```

For a repack image, `org.opencontainers.image.version` should identify the
published image release, including the repack revision where appropriate.
The upstream application version belongs in the repository-specific metadata.

`org.opencontainers.image.base.name` and `org.opencontainers.image.base.digest`
describe the immediate image base, not every image used in a multi-stage
build. Multi-stage inputs belong in the provenance attestation.

Where tooling permits, put standard metadata on the image index and each
platform manifest. Build-tool config labels may also mirror the standard
values for compatibility with older inspection tools, but the values must not
diverge.

### Required repository-specific annotations

For every published image, use the following keys when the value exists:

```text
com.samhclark.oci-redist.kind
com.samhclark.oci-redist.compatibility
com.samhclark.oci-redist.upstream.project
com.samhclark.oci-redist.upstream.version
com.samhclark.oci-redist.upstream.image
com.samhclark.oci-redist.upstream.digest
com.samhclark.oci-redist.repack.revision
com.samhclark.oci-redist.build.repository
com.samhclark.oci-redist.build.commit
com.samhclark.oci-redist.build.workflow
com.samhclark.oci-redist.manifest
```

Recommended values:

```text
com.samhclark.oci-redist.kind=mirror|repack
com.samhclark.oci-redist.compatibility=exact-image|application
com.samhclark.oci-redist.upstream.project=https://github.com/caddyserver/caddy
com.samhclark.oci-redist.upstream.version=2.11.4
com.samhclark.oci-redist.upstream.image=docker.io/library/caddy:2.11.4
com.samhclark.oci-redist.upstream.digest=sha256:<source-manifest-digest>
com.samhclark.oci-redist.repack.revision=1
com.samhclark.oci-redist.build.repository=https://github.com/samhclark/oci-redist
com.samhclark.oci-redist.build.commit=<full-git-sha>
com.samhclark.oci-redist.build.workflow=https://github.com/.../actions/runs/...
com.samhclark.oci-redist.manifest=https://github.com/samhclark/oci-redist/blob/main/images/caddy-repack.yaml
```

`upstream.image` and `upstream.digest` identify the exact image input when
there is one. A repack built from an application release or source checkout
can omit `upstream.image` and instead identify the project, version, commit,
and source archive digest.

Do not put a large JSON dependency list into an annotation. Annotations are
for discovery and scalar identity. Use attestations for structured build
inputs, patches, plugins, and multiple upstream materials.

### Optional annotations

These are useful when applicable:

```text
com.samhclark.oci-redist.upstream.source-commit
com.samhclark.oci-redist.upstream.source-digest
com.samhclark.oci-redist.patch-set
com.samhclark.oci-redist.plugins
com.samhclark.oci-redist.sbom
com.samhclark.oci-redist.provenance
```

Values should be short, stable references such as a URL or digest. The
complete patch and plugin inventory belongs in the build manifest and
provenance attestation.

## Mirror integrity

An exact mirror must not mutate the copied image to add local labels or
annotations. Changing the config or manifest changes the image digest and
breaks the exact-mirror promise.

The mirror pipeline should:

1. resolve the upstream tag to a manifest or index digest;
2. verify the upstream signature when one exists;
3. copy all platforms and referenced layers without mutation;
4. verify that the destination digest matches the source digest;
5. sign the destination digest with the `oci-redist` publishing identity; and
6. attach a copy/provenance attestation describing the source and verification
   result.

The local signature is still useful even when the image is an exact mirror:
it lets consumers trust the destination registry and the redistribution
workflow. It does not claim that `oci-redist` authored the upstream software.

If annotations are required for cataloging an exact mirror, store them in a
repository manifest or signed provenance attestation rather than mutating the
image itself.

## Repack provenance

Every `*-repack` build should produce a signed provenance attestation. At
minimum it should identify:

- the `oci-redist` repository and commit;
- the CI workflow and run identifier;
- the final image digest;
- the exact upstream image digest or source commit;
- the immediate base image digest;
- every additional image used by a multi-stage build;
- patch files and their digests;
- plugin/module source repositories and versions;
- build arguments and relevant feature flags; and
- the builder/toolchain identity.

For Caddy this should explicitly name the Caddy source/image digest, the
Cloudflare module version and source commit, and the DNS patch revision.

The image name remains `caddy-repack`; the provenance tells consumers what
that particular revision contains.

## SBOM policy

Publish an SBOM for every final image digest, including exact mirrors.

The SBOM should be generated from the final published image digest, not from a
tag, source checkout, or intermediate build stage. This ensures that the SBOM
describes what consumers actually pull.

Preferred policy:

- SPDX JSON is the canonical SBOM format;
- CycloneDX JSON may be published additionally when a consumer requires it;
- attach the SBOM as a signed OCI/in-toto attestation referring to the final
  image digest;
- optionally publish a downloadable copy keyed by image digest for offline
  inspection; and
- do not add the SBOM to the runtime image filesystem merely to distribute it.

For mirrors, the SBOM describes the unchanged upstream image and the
attestation records that the image was copied without mutation. For repacks,
the SBOM must include the final base userspace, application payload, plugins,
and runtime packages.

An SBOM is not a vulnerability-free guarantee. Run vulnerability scanning as
an independent CI and scheduled process, and retain scan reports separately
from the SBOM attestation.

## Signature policy

Sign every published final image digest. Signatures must be attached to the
digest, never treated as a property of a mutable tag.

Recommended model:

- use Sigstore keyless signing from the protected GitHub Actions workflow when
  ordinary consumers can verify GitHub/Sigstore identity;
- also use a stable project signing key, preferably backed by a KMS or other
  protected signing service, when the image will be consumed by boot-time
  signature policy that needs a pinned public key;
- keep the private signing material out of Git and out of the image;
- publish the public verification key through the consumer project and a
  documented out-of-band location; and
- define a key-rotation procedure before the first production image is
  consumed.

For a mirror, verify the upstream artifact first and then sign the unchanged
destination digest with the local publishing identity. For a repack, sign the
new final digest after the build and verification gates pass.

Sign or attest the following separately:

1. the final image index or manifest;
2. the SBOM attestation;
3. the build provenance attestation; and
4. optional vulnerability or policy reports.

Consumers should verify signatures and attestations against the exact digest,
then apply policy to the signer identity, repository, workflow, and expected
attestation type.

## Release gates

### Mirror release

- source reference resolves to an immutable digest;
- source signature is verified when available;
- all platforms are copied;
- destination digest equals source digest;
- local signature is present;
- SBOM attestation is present; and
- copy/provenance attestation records the source digest and workflow.

### Repack release

- all upstream inputs are digest-pinned;
- source and base image provenance is recorded;
- the application-specific smoke test passes;
- the image contract test passes for user, entrypoint, paths, signals, and
  health behavior;
- the final image is scanned;
- SBOM and provenance attestations are attached;
- the final digest is signed; and
- release notes describe changes since the previous `redist.N` revision.

## References

- [OCI image annotations](https://github.com/opencontainers/image-spec/blob/main/annotations.md)
- [OCI image specification](https://github.com/opencontainers/image-spec/blob/main/spec.md)
- [OCI image layout and descriptor references](https://github.com/opencontainers/image-spec/blob/main/image-layout.md)
- [Sigstore container signing](https://docs.sigstore.dev/cosign/signing/signing_with_containers/)
- [Sigstore verification](https://docs.sigstore.dev/cosign/verifying/verify/)
- [Sigstore SBOM signing and attestation](https://docs.sigstore.dev/cosign/signing/other_types/)
- [Syft SBOM attestations](https://github.com/anchore/syft/wiki/attestation)
