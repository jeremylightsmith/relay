#!/usr/bin/env python3
"""Write example boards' stages and flows into their template files.

The writer behind `prod pull-demo-flows`. Reads `{slug: {"stages", "flows"}}` as JSON on
stdin (`Hamaca.Release.example_template_parts/1`) and replaces those two keys in
docs/designs/templates/<slug>.json. Everything else in the file — the picker copy and the
agents — is kept.

The files are hand-formatted, so this writes them in the same style rather than json.dump's:
stages, agents, edges and control nodes one per line, other nodes one key per line. An existing
node keeps its key order; a new node gets key and type first and run last. Writing a file's own
parts back is a no-op, so a pull with nothing changed leaves git clean.

Usage: pull_demo_flows.py <templates-dir> < parts.json
"""
import json
import pathlib
import sys

PARTS = ("stages", "flows")
FLOW_KEYS = ("key", "isolation", "trigger", "nodes", "edges")


def dump(value):
    return json.dumps(value, ensure_ascii=False)


def padded(obj):
    """`{ "from": "a", "to": "b" }` — the style edges, triggers and control nodes use."""
    return "{ " + dump(obj)[1:-1] + " }"


def joined(blocks):
    """Each block's lines indented two spaces, with a comma ending every block but the last."""
    out = []
    for n, block in enumerate(blocks):
        lines = ["  " + line for line in block]
        if n < len(blocks) - 1:
            lines[-1] += ","
        out.extend(lines)
    return out


def array(blocks):
    return ["[", *joined(blocks), "]"] if blocks else ["[]"]


def obj(pairs):
    """`pairs` of (key, value lines) as a multi-line object."""
    return ["{", *joined([[f"{dump(key)}: {lines[0]}", *lines[1:]] for key, lines in pairs]), "}"]


def key_order(items, seed=()):
    """Every key in `items`, in first-seen order after `seed` — the file's order for that kind."""
    order = list(seed)
    for item in items:
        order += [k for k in item if k not in order]
    return order


def ordered(item, order):
    """`item` with its keys in `order`; keys `order` lacks go last, alphabetically.

    The parts arrive alphabetized (Jason encodes Elixir maps that way), so this is what puts
    "name" back before "category".
    """
    known = [k for k in order if k in item]
    return {k: item[k] for k in known + sorted(k for k in item if k not in known)}


def node_order(existing):
    """A node's keys: its own existing order, new keys after them (key and type first), run last."""
    def rank(key):
        return ({"key": 0, "type": 1}.get(key, 2), key)

    def order(node):
        keys = [k for k in existing if k in node] + sorted((k for k in node if k not in existing), key=rank)
        return [k for k in keys if k != "run"] + (["run"] if "run" in node else [])

    return order


class Orders:
    """The key order of each kind of object, read from the file before its parts are replaced."""

    def __init__(self, doc):
        flows = doc.get("flows", [])
        self.stage = key_order(doc.get("stages", []))
        self.flow = key_order(flows, FLOW_KEYS)
        self.edge = key_order(e for f in flows for e in f["edges"])
        self.nodes = {f["key"]: {n["key"]: list(n) for n in f["nodes"]} for f in flows}


def render_node(node, order):
    node = {k: node[k] for k in order(node)}
    if "run" not in node:  # a control node (fan_out / fan_in)
        return [padded(node)]
    return obj([(k, [dump(v)]) for k, v in node.items()])


def render_flow(flow, orders):
    old_nodes = orders.nodes.get(flow["key"], {})

    def value(key):
        if key == "trigger":
            return [padded(flow[key])]
        if key == "nodes":
            return array([render_node(n, node_order(old_nodes.get(n.get("key"), []))) for n in flow[key]])
        if key == "edges":
            return array([[padded(ordered(e, orders.edge))] for e in flow[key]])
        return [dump(flow[key])]

    return obj([(k, value(k)) for k in ordered(flow, orders.flow)])


def merge(text, parts):
    """`text` (a template file) with its stages and flows replaced by `parts`."""
    doc = json.loads(text)
    orders = Orders(doc)
    doc.update({key: parts[key] for key in PARTS})

    def value(key):
        if key == "stages":
            return array([[dump(ordered(s, orders.stage))] for s in doc[key]])
        if key == "agents":  # not pulled, but written in the file's one-per-line style
            return array([[dump(a)] for a in doc[key]])
        if key == "flows":
            return array([render_flow(f, orders) for f in doc[key]])
        return [dump(doc[key])]

    return "\n".join(obj([(k, value(k)) for k in doc])) + "\n"


def main():
    templates = pathlib.Path(sys.argv[1])
    for slug, parts in json.load(sys.stdin).items():
        path = templates / f"{slug}.json"
        path.write_text(merge(path.read_text(), parts))
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
