# just manual: https://github.com/casey/just/#readme

_default:
    @just --list

@butane:
    podman run --rm --interactive         \
              --security-opt label=disable          \
              --volume "${PWD}":/pwd --workdir /pwd \
              quay.io/coreos/butane:release