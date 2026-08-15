#!/usr/bin/env python3
"""Stateful PATH shim for nas-prepare-storage behavioral tests."""

import json
import os
import sys
from pathlib import Path


STATE_PATH = Path(os.environ["FAKE_STORAGE_STATE"])
LOG_PATH = Path(os.environ["FAKE_STORAGE_LOG"])
COMMAND = Path(sys.argv[0]).name
ARGS = sys.argv[1:]
EXPECTED_LABEL = "system_u:object_r:container_file_t:s0"


def load_state():
    return json.loads(STATE_PATH.read_text())


def save_state(state):
    temporary = STATE_PATH.with_suffix(".new")
    temporary.write_text(json.dumps(state, sort_keys=True))
    temporary.replace(STATE_PATH)


def log_command():
    with LOG_PATH.open("a") as log:
        print(json.dumps([COMMAND, *ARGS]), file=log)


def fail(message=""):
    if message:
        print(message, file=sys.stderr)
    raise SystemExit(1)


def path_state(state, path):
    try:
        return state["paths"][path]
    except KeyError:
        fail(f"unknown fake path: {path}")


def descendants(state, root):
    return state.get("samples", {}).get(root, [])


def zpool(state):
    if ARGS == ["list", "-H", "-o", "name"]:
        print("\n".join(state["pools"]))
        return
    fail(f"unsupported zpool invocation: {ARGS}")


def zfs(state):
    if ARGS == ["list", "-H", "-o", "name"]:
        print("\n".join(state["datasets"]))
        return

    if ARGS and ARGS[0] == "get":
        if ARGS[1:4] != ["-H", "-o", "property,value"] or len(ARGS) != 6:
            fail(f"unsupported zfs get invocation: {ARGS}")
        requested = ARGS[4].split(",")
        dataset = state["datasets"].get(ARGS[5])
        if dataset is None:
            fail("missing dataset")
        for key in requested:
            try:
                value = dataset["properties"][key]
            except KeyError:
                fail(f"missing property {key}")
            print(f"{key}\t{value}")
        return

    if ARGS and ARGS[0] == "create":
        dataset_name = ARGS[-1]
        if dataset_name in state["datasets"]:
            fail("dataset already exists")
        properties = {}
        index = 1
        while index < len(ARGS) - 1:
            if ARGS[index] != "-o" or index + 1 >= len(ARGS) - 1:
                fail(f"unsupported zfs create invocation: {ARGS}")
            key, value = ARGS[index + 1].split("=", 1)
            properties[key] = value
            index += 2
        state["datasets"][dataset_name] = {"properties": properties}
        mountpoint = properties["mountpoint"]
        if mountpoint != "none":
            Path(mountpoint).mkdir(parents=True)
            state["paths"][mountpoint] = {
                "label": "system_u:object_r:unlabeled_t:s0",
                "mode": "755",
                "owner": "0:0",
            }
            state.setdefault("samples", {})[mountpoint] = []
        save_state(state)
        return

    fail(f"unsupported zfs invocation: {ARGS}")


def getent(state):
    if len(ARGS) == 2 and ARGS[0] == "passwd" and ARGS[1] in state["users"]:
        user = state["users"][ARGS[1]]
        print(f"{ARGS[1]}:x:{user['uid']}:{user['gid']}::/nonexistent:/usr/sbin/nologin")
        return
    fail("unknown user")


def id_command(state):
    if len(ARGS) == 2 and ARGS[1] in state["users"]:
        user = state["users"][ARGS[1]]
        if ARGS[0] == "-u":
            print(user["uid"])
            return
        if ARGS[0] == "-g":
            print(user["gid"])
            return
    fail(f"unsupported id invocation: {ARGS}")


def findmnt(state):
    if ARGS[:4] != ["-rn", "-o", "SOURCE", "-T"] or len(ARGS) != 5:
        fail(f"unsupported findmnt invocation: {ARGS}")
    requested_path = ARGS[4]
    for name, dataset in state["datasets"].items():
        if dataset["properties"].get("mountpoint") == requested_path:
            print(name)
            return
    fail("not mounted")


def stat_command(state):
    if len(ARGS) != 4 or ARGS[0] != "-c" or ARGS[2] != "--":
        fail(f"unsupported stat invocation: {ARGS}")
    item = path_state(state, ARGS[3])
    values = {"%C": item["label"], "%a": item["mode"], "%u:%g": item["owner"]}
    try:
        print(values[ARGS[1]])
    except KeyError:
        fail(f"unsupported stat format: {ARGS[1]}")


def find_command(state):
    root = ARGS[0]
    children = descendants(state, root)

    def mapped_id(value, kind):
        declarations = [
            ARGS[index + 1]
            for index, argument in enumerate(ARGS[:-1])
            if argument == f"-{kind}"
        ]
        primary = next(int(item) for item in declarations if item.isdigit())
        lower = next(int(item[1:]) + 1 for item in declarations if item.startswith("+"))
        upper = next(int(item[1:]) for item in declarations if item.startswith("-"))
        return value == primary or lower <= value < upper

    def mapped_owner(child):
        uid, gid = (
            int(value) for value in path_state(state, child)["owner"].split(":", 1)
        )
        return mapped_id(uid, "uid") and mapped_id(gid, "gid")

    if "-maxdepth" in ARGS:
        if children:
            print(children[0])
        return

    if "-exec" in ARGS:
        owner_arg = ARGS[ARGS.index("chown") + 2]
        for child in children:
            if not mapped_owner(child):
                path_state(state, child)["owner"] = owner_arg
        save_state(state)
        return

    if "-uid" in ARGS and "-gid" in ARGS:
        for child in children:
            if not mapped_owner(child):
                print(child)
                return
        return

    fail(f"unsupported find invocation: {ARGS}")


def matchpathcon(state):
    if len(ARGS) != 2 or ARGS[0] != "-n":
        fail(f"unsupported matchpathcon invocation: {ARGS}")
    path = ARGS[1]
    if any(path == root or path.startswith(f"{root}/") for root in state["fcontexts"]):
        print(EXPECTED_LABEL)
    else:
        print("system_u:object_r:var_lib_t:s0")


def semanage(state):
    if len(ARGS) != 7 or ARGS[0] != "fcontext" or ARGS[1] not in {"-a", "-m"}:
        fail(f"unsupported semanage invocation: {ARGS}")
    action = ARGS[1]
    target = ARGS[-1]
    suffix = "(/.*)?"
    if not target.endswith(suffix):
        fail("unexpected fcontext expression")
    root = target[: -len(suffix)].replace(r"\.", ".")
    exists = root in state["fcontexts"]
    if action == "-a" and exists:
        fail("already exists")
    if action == "-m" and not exists:
        fail("does not exist")
    if not exists:
        state["fcontexts"].append(root)
    save_state(state)


def restorecon(state):
    root = ARGS[-1]
    path_state(state, root)["label"] = EXPECTED_LABEL
    for child in descendants(state, root):
        path_state(state, child)["label"] = EXPECTED_LABEL
    save_state(state)


def install(state):
    if not ARGS or ARGS[0] != "-d":
        fail(f"unsupported install invocation: {ARGS}")
    mode = ARGS[ARGS.index("-m") + 1].removeprefix("0")
    uid = ARGS[ARGS.index("-o") + 1]
    gid = ARGS[ARGS.index("-g") + 1]
    path = ARGS[-1]
    Path(path).mkdir(parents=True, exist_ok=True)
    state["paths"][path] = {
        "label": "system_u:object_r:unlabeled_t:s0",
        "mode": mode,
        "owner": f"{uid}:{gid}",
    }
    state.setdefault("samples", {})[path] = []
    save_state(state)


def chown(state):
    owner = ARGS[0]
    if owner == "root:root":
        owner = "0:0"
    for path in ARGS[1:]:
        path_state(state, path)["owner"] = owner
    save_state(state)


def chmod(state):
    mode = ARGS[0].removeprefix("0")
    for path in ARGS[1:]:
        path_state(state, path)["mode"] = mode
    save_state(state)


def runuser(state):
    try:
        podman_index = ARGS.index("podman")
    except ValueError:
        fail(f"unsupported runuser invocation: {ARGS}")
    podman_args = ARGS[podman_index + 1 :]
    if podman_args[:2] == ["container", "exists"]:
        raise SystemExit(0 if state.get("container_exists", False) else 1)
    if podman_args and podman_args[0] == "inspect" and state.get("container_exists", False):
        print("true" if state.get("container_running", False) else "false")
        return
    fail(f"unsupported fake podman invocation: {podman_args}")


def ss(state):
    if state.get("ss_fails", False):
        fail("ss failure")
    print("\n".join(state.get("listeners", [])))


def main():
    state = load_state()
    log_command()
    handlers = {
        "chmod": chmod,
        "chown": chown,
        "find": find_command,
        "findmnt": findmnt,
        "getent": getent,
        "id": id_command,
        "install": install,
        "matchpathcon": matchpathcon,
        "restorecon": restorecon,
        "runuser": runuser,
        "semanage": semanage,
        "ss": ss,
        "stat": stat_command,
        "zfs": zfs,
        "zpool": zpool,
    }
    try:
        handler = handlers[COMMAND]
    except KeyError:
        fail(f"unsupported fake command: {COMMAND}")
    handler(state)


if __name__ == "__main__":
    main()
