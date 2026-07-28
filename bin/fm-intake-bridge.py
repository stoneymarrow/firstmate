#!/usr/bin/env python3
"""Bridge from Firstmate's chat adapter to Launchpad's canonical intake API.

Launchpad owns the classifier, the class set, the confidence rule, the routing
table, the duplicate identity and the shared autonomous-pickup declaration.
This file adds no rule of its own: it exists so `bin/fm-intake.sh` can reach
that one API from bash, and it refuses rather than guessing when the API is not
importable. A second classifier on the Firstmate side would drift from the one
in Launchpad within a week, which is exactly what the shared contract forbids.

Modes:

  pickup    resolve the shared declaration and print its current value.
  capture   classify ONE chat capture through `launchpad.intake.capture` with
            origin "chat", then report what was filed, linked or retained.

Output is a tab-separated record stream on stdout, one record per line, with no
tab or newline inside a field (Launchpad collapses capture whitespace, and every
reason it emits is generated prose):

  pickup   <on|off>  <describe()>
  filed    <source_id>  <class>  <destination>  <1|0 dispatch eligible>  <path>  <text>
  linked   <source_id>  <class>  <linked_to>  <text>
  retained <source_id>  <class>  <reason>  <text>
  error    <code>  <detail>

`--json-out <path>` additionally writes the full result as one JSON object.
Exit status: 0 on success, 3 when the shared classifier or declaration cannot be
reached. Every failure prints an `error` record and files nothing.
"""
from __future__ import annotations

import argparse
import json
import sys

_UNAVAILABLE = 3


def _emit(*fields: object) -> None:
    print("\t".join("" if f is None else str(f) for f in fields))


def _fail(code: str, detail: str) -> None:
    _emit("error", code, " ".join(str(detail).split()))
    raise SystemExit(_UNAVAILABLE)


def _parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("mode", choices=("pickup", "capture"))
    ap.add_argument("--text", default="")
    ap.add_argument("--class", dest="cls", default="")
    ap.add_argument("--project", default="")
    ap.add_argument("--topic", default="")
    ap.add_argument("--name", default="")
    ap.add_argument("--confidence", default="")
    ap.add_argument("--date", default="")
    ap.add_argument("--backlog", action="store_true")
    ap.add_argument("--items", default="")
    ap.add_argument("--json-out", dest="json_out", default="")
    return ap.parse_args()


def _proposal(args: argparse.Namespace) -> dict:
    """One agent proposal in Launchpad's shape. Only stated fields are sent, so
    an absent confidence stays absent and Launchpad's own rule decides."""
    item: dict = {"text": args.text}
    if args.cls:
        item["type"] = args.cls
    if args.project:
        item["project"] = args.project
    if args.topic:
        item["topic"] = args.topic
    if args.name:
        item["name"] = args.name
    if args.confidence:
        item["confidence"] = args.confidence
    if args.date:
        item["date"] = args.date
    if args.backlog:
        item["backlog"] = True
    return item


def main() -> None:
    args = _parse_args()
    try:
        from launchpad import classify, config as lp_config, intake, pickup
    except Exception as exc:  # noqa: BLE001 - any import failure is "unavailable"
        _fail("classifier-unavailable", f"{exc.__class__.__name__}: {exc}")
        return

    try:
        cfg = lp_config.load_config()
        state = pickup.read(cfg)
        described = pickup.describe(cfg)
    except Exception as exc:  # noqa: BLE001
        _fail("declaration-unreadable", f"{exc.__class__.__name__}: {exc}")
        return

    _emit("pickup", "on" if state.enabled else "off", described)

    if args.mode == "pickup":
        if args.json_out:
            _write_json(args.json_out, {
                "ok": True, "pickup": described, "pickup_enabled": state.enabled,
                "pickup_reason": state.reason, "declaration": state.source})
        return

    text = " ".join(str(args.text).split())
    if not text:
        _fail("empty-capture", "no capture text was given")

    structure = None
    if args.items:
        try:
            items = json.loads(args.items)
        except ValueError as exc:
            _fail("bad-proposal", f"--items is not JSON: {exc}")
            return
        if not isinstance(items, list) or not all(isinstance(i, dict) for i in items):
            _fail("bad-proposal", "--items must be a JSON list of objects")
        structure = lambda _text, _items=items: _items  # noqa: E731
    elif args.cls or args.confidence or args.project or args.topic or args.name:
        one = _proposal(args)
        structure = lambda _text, _one=one: [_one]  # noqa: E731

    try:
        vault_root = lp_config.vault_root(cfg)
        data_dir = lp_config.data_dir(cfg)
        result = intake.capture(vault_root, data_dir, text, structure=structure,
                                origin="chat", pickup_config=cfg)
    except Exception as exc:  # noqa: BLE001
        _fail("capture-failed", f"{exc.__class__.__name__}: {exc}")
        return

    def identified(rows: list) -> list:
        out = []
        for row in rows or []:
            row = dict(row)
            if not row.get("source_id"):
                row["source_id"] = classify.source_id(row.get("text", ""))
            out.append(row)
        return out

    filed = identified(result.get("items", []))
    linked = identified(result.get("linked_items", []))
    retained = identified(result.get("retained_items", []))

    for row in filed:
        _emit("filed", row["source_id"], row.get("type", ""),
              row.get("destination", ""),
              1 if row.get("dispatch_eligible") else 0,
              row.get("path", ""), row.get("text", ""))
    for row in linked:
        _emit("linked", row["source_id"], row.get("class", row.get("type", "")),
              row.get("linked_to", ""), row.get("text", ""))
    for row in retained:
        _emit("retained", row["source_id"], row.get("class", row.get("type", "")),
              " ".join(str(row.get("reason", "")).split()), row.get("text", ""))

    if args.json_out:
        _write_json(args.json_out, {
            "ok": True, "pickup": described, "pickup_enabled": state.enabled,
            "pickup_reason": state.reason, "declaration": state.source,
            "vault_root": str(vault_root), "origin": "chat",
            "filed": filed, "linked": linked, "retained": retained})


def _write_json(path: str, payload: dict) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2, default=str)
        f.write("\n")


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:  # pragma: no cover - defensive
        sys.exit(_UNAVAILABLE)
