# Release and testing architecture

## Canonical developer gates

The public Make interface intentionally keeps different questions separate:

- `make deps` verifies the development toolchain.
- `make check` performs static, non-mutating validation.
- `make test` runs behavioral tests.
- `make build` resolves current external inputs once and assembles the image.
- `make publish` explicitly triggers the production publishing workflow.
- `make all` gates the build behind deps, checks, and tests.

CI calls the same `check` and `test` commands through the reusable build
preflight workflow. Generated parity has a read-only compiler mode; validation
must never repair the working tree.

## Testing ladder

The testing layers are:

1. Source contracts and behavioral tests with no host mutation.
2. Exact built-image contract validation without booting it.
3. An explicit local QCOW2/QEMU boot smoke test with no guest network, host
   block device, production secret, or ZFS pool.

Layers 1 and 2 are active. Every `make build` runs the exact-image contract
against the tag it just produced; `make verify-image` can repeat that read-only
contract without rebuilding.

The layer 3 runner is implemented as an opt-in local test for a separately
created, fresh QCOW2:

```console
make deps-vm
make test-vm QCOW=/absolute/path/to/fresh-image.qcow2
```

The runner does not create, convert, commit, rebase, or delete the supplied
image. It accepts only a regular, non-symlink, standalone QCOW2 with no backing
or external data file and passes a read-only integrity check. QEMU boots exactly
that one disk with `-snapshot`, a private temporary overlay, no NIC, and no host
filesystem passthrough. The runner checks the base image hash after shutdown.

The test Ignition masks service-user managers, updates, secrets, storage
preparation, and ZFS maintenance before testing bootc, SELinux, the ZFS module,
accounts, each per-user Quadlet, TAP creation, and nftables. Serial and QEMU
logs are retained under `build/vm-smoke/`; there is intentionally no cleanup
routine. The strict build-context allowlist and exact-image contract separately
prove that `tests/`, this fixture, and the host runner are not shipped.

The runner has passed behavioral fake-tool safety tests, strict Butane
validation, and a local QEMU capability probe, but an end-to-end guest pass is
not claimed yet because no fresh QCOW2 was available during implementation.
`make check` validates the test Ignition; actually booting the VM is not part of
`make check`, `make test`, `make build`, `make all`, or CI.

Automatic OCI-to-QCOW2 conversion is deliberately deferred. The supported
unified `image-builder` was not installed during the local capability spike,
and its current local-image transport addresses the rootful container store
directly. Bridging the rootless development image into that store would require
a privileged mount-and-cleanup workflow that is a worse safety boundary than
requiring an explicit QCOW2 input. The older `bootc-image-builder` path is
[deprecated upstream](https://osbuild.org/docs/bootc/deprecation-notice/).

A scratch ZFS-pool acceptance VM is deliberately deferred. No pool fixture or
teardown helper may be shipped in the image, and no test is allowed to target
the production NAS.

## Publishing decision

The scheduled publisher is serialized and never cancels an in-progress run.
It currently moves the `stable` tag before attaching the signature and
attestation to the resulting digest.

The host's containers/image policy rejects an unsigned `custom-coreos` image,
so the accepted failure mode during that short window is a refused or delayed
update rather than accepting unsigned content. Candidate-to-stable promotion
is deferred until there is an automated candidate gate worth placing between
build and promotion.

Revisit this decision if there is more than one consumer, if update retry
behavior changes, or when image/VM validation can run against the candidate
digest in CI.

## Production boundary

Agents never SSH to or execute on the NAS. Live evidence is collected only by
the operator using a reviewed, minimal copy-paste command. Test infrastructure
must make production targeting structurally impossible rather than relying on
a warning or teardown discipline.
