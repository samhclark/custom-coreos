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

The supported and planned layers are:

1. Source contracts and behavioral tests with no host mutation.
2. Exact built-image contract validation without booting it.
3. An explicit local QCOW2/QEMU boot smoke test with no network, host block
   device, production secret, or ZFS pool.

Layer 1 is active. Layers 2 and 3 are implementation work and must not be
described as passing gates until their commands work end to end.

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
