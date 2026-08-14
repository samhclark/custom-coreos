# Applications, services, endpoints, and startup dependencies

## Mental model

The deployment model has four deliberately small concepts:

- An **application** groups components that deliver one user-facing capability,
  such as `immich` or `observability`.
- A **service** is one independently supervised container with its own host
  identity, libkrun guest, resources, secrets, and storage declarations.
- A service's **role** names its unique job within the application, such as
  `server`, `database`, or `cache`.
- A named **endpoint** is a listener offered by a service. It owns its protocol,
  container port, optional host publication, and allowed service consumers.

Application membership is descriptive. It does not create a shared security
boundary, user account, lifecycle unit, network, storage tree, or backup policy.
Those remain explicit per service or endpoint. The compiler rejects duplicate
roles within an application so that `immich/server` identifies exactly one
component.

This is intentionally smaller than a Kubernetes-style workload API. For one
NAS, the useful part is a consistent vocabulary and validation of relationships,
not a generic orchestrator.

## Named endpoints

Listeners are declared once:

```toml
[[container.endpoints]]
name = "postgres"
port = 5432
consumers = ["immich-server"]
```

`consumers` generates the inter-TAP allowlist. An optional `host` value such as
`127.0.0.1:2283` or `0.0.0.0:443` generates host publication. A TAP service's
`probe-endpoint` refers to one named TCP endpoint for its post-start listener
check. This prevents port numbers in probes, publications, and network policy
from becoming unrelated copies.

The provider owns the endpoint and its consumer allowlist. A consumer cannot
declare access to a port the provider did not expose.

## Startup dependencies

A service may wait for several named endpoints before it starts:

```toml
[[startup.dependencies]]
service = "immich-database"
endpoint = "postgres"
condition = "tcp"
timeout-sec = 120
interval-sec = 2

[[startup.dependencies]]
service = "immich-machine-learning"
endpoint = "http"
condition = "http"
path = "/ping"
timeout-sec = 120
interval-sec = 2
```

The compiler resolves each target to its TAP guest address and endpoint port.
It also requires the target endpoint to list the dependent service as a
consumer, so startup assumptions and network authorization cannot disagree.
These checks are bounded startup gates, not ongoing health supervision or
cross-manager systemd dependencies. They compose with generated storage
readiness when a component needs both.

## Immich as the proving case

The production Immich application has `server`, `database`, `cache`, and
`machine-learning` roles. The server combines storage readiness with named TCP
dependencies on PostgreSQL and Valkey. Machine learning remains independently
restartable: the server knows its named address, but core photo availability is
not coupled to model-service startup.

This deployment also forced two intentionally narrow container additions:
typed shared-memory sizing for PostgreSQL and the official rootless hardening
fields (`no-new-privileges` and dropped capabilities). A positive
`container-user` generates both `User=UID:GID` and a matching `keep-id` user
namespace. The service host identity therefore remains the owner of its
declared storage, while the intended application identity appears inside the
container as UID/GID 1000:1000.

Immich PostgreSQL needs one additional, image-specific compatibility boundary.
The upstream wrapper alone does not prove the production UID contract: under
libkrun, the guest can enter the wrapper as guest root even when the generated
unit requests `User=1000:1000`. The database service consequently mounts the
small image-controlled `/usr/share/custom-coreos/immich-database/` adapter
tree read-only and invokes it as its entrypoint. The adapter has two supported
branches:

- If it starts as guest root, it uses the image's existing `gosu` to become
  1000:1000 before delegating to the upstream Immich PostgreSQL wrapper.
- If it starts as 1000:1000, it delegates directly without changing ownership.

This preserves the storage ownership rule in both runtimes. The Podman image
smoke exercises both branches, while the opt-in `make probe-krun-user` command
characterizes the identity that the actual libkrun runtime supplies. The
adapter is deliberately scoped to this demonstrated image/runtime boundary;
it is not a general replacement for a compatible upstream entrypoint.

The next useful proving case is the *arr stack, especially shared storage and a
VPN-constrained network path. Concrete needs from that suite should drive any
further schema growth.
