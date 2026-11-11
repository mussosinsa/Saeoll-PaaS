#!/usr/bin/env python3
"""Web address of an application in the gitops repository: apps/<app>/{base,overlays/<env>} (app-expose.sh).

convert <app-dir> <app> <ingress|virtualservice> <dev-patch-file> <prod-patch-file>
    base/kustomization.yaml : resource ingress.yaml <-> virtualservice.yaml
    overlays/<env>          : the host patch of the old kind (Ingress / VirtualService of <app>) is replaced by the
                              lines of <env>-patch-file (lib.sh expose_patch). Other patches (autoscale, ...) are kept.
    Prints "changed" or "unchanged". The base file itself is written by app-expose.sh (rendered template).
"""
import os
import re
import sys

KINDS = {"ingress": "Ingress", "virtualservice": "VirtualService"}


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().splitlines()


def write(path, lines):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def replace_patch(lines, app, new_block):
    """Replace the '- target: kind Ingress|VirtualService, name <app>' entry of 'patches:' by new_block."""
    out, i, replaced = [], 0, False
    while i < len(lines):
        line = lines[i]
        if line == "  - target:" and i + 2 < len(lines) and \
                re.match(r"^      kind: (Ingress|VirtualService)\s*$", lines[i + 1]) and \
                lines[i + 2].strip() == f"name: {app}":
            j = i + 1
            while j < len(lines) and lines[j].startswith("    ") and not lines[j].startswith("  - "):
                j += 1
            if not replaced:
                out.extend(new_block)
                replaced = True
            i = j
            continue
        out.append(line)
        i += 1
    if not replaced:                              # no host patch yet: add it to 'patches:' (create if missing)
        if "patches:" not in out:
            out.append("patches:")
        k = out.index("patches:") + 1
        out[k:k] = new_block
    return out


def convert(app_dir, app, kind, dev_patch, prod_patch):
    changed = False
    kfile = os.path.join(app_dir, "base", "kustomization.yaml")
    lines = read(kfile)
    new_file, old_file = ("virtualservice.yaml", "ingress.yaml") if kind == "virtualservice" else \
        ("ingress.yaml", "virtualservice.yaml")
    res = [f"  - {new_file}" if line.strip() == f"- {old_file}" else line for line in lines]
    if f"  - {new_file}" not in res:
        k = res.index("resources:") + 1 if "resources:" in res else len(res)
        res[k:k] = [f"  - {new_file}"]
    if res != lines:
        write(kfile, res)
        changed = True
    for env, patch in (("dev", dev_patch), ("prod", prod_patch)):
        ofile = os.path.join(app_dir, "overlays", env, "kustomization.yaml")
        if not os.path.exists(ofile):
            continue
        block = [line for line in read(patch) if line.strip()]
        lines = read(ofile)
        new = replace_patch(lines, app, block)
        if new != lines:
            write(ofile, new)
            changed = True
    return changed


def main():
    if len(sys.argv) != 7 or sys.argv[1] != "convert" or sys.argv[4] not in KINDS:
        raise SystemExit(__doc__)
    print("changed" if convert(*sys.argv[2:7]) else "unchanged")


if __name__ == "__main__":
    main()
