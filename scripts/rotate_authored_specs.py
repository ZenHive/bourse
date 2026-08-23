#!/usr/bin/env python3
"""Split facet-major authored spec.json files into endpoint-major documents.

Run from the repo root. Writes the split layout, then reassembles and asserts
deep equality against the original maps before deleting spec.json.
"""

from __future__ import annotations

import hashlib
import json
import shutil
from collections import OrderedDict
from pathlib import Path

ROOT = Path("priv/venues")
SHARED = ROOT / "_shared" / "binance_family" / "descriptors.json"
BINANCE_FAMILY = ("binance", "binancecoinm", "binanceusdm")
HTTP_VERBS = {"delete", "get", "head", "patch", "post", "put"}
COST_KEYS = {"byLimit", "cost", "noSymbol"}

VENUE_TOP = (
    "schema_version",
    "authored",
    "frozen",
    "hand_owned",
    "exchange",
    "urls",
    "testnet",
    "auth",
    "config",
    "fees",
    "websocket",
    "emulated_methods",
)


def load_json(path: Path):
    with path.open() as fh:
        return json.load(fh, object_pairs_hook=OrderedDict)


def dump_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as fh:
        json.dump(value, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


def is_cost_object(value) -> bool:
    return isinstance(value, dict) and bool(value) and set(value) <= COST_KEYS


def walk_api(obj, path=()):
    if isinstance(obj, dict):
        if is_cost_object(obj) or obj == {}:
            yield path, obj
            return
        for key, val in obj.items():
            yield from walk_api(val, path + (key,))
        return
    yield path, obj


def unflatten_api(endpoints: dict) -> OrderedDict:
    tree = OrderedDict()
    for key, obj in endpoints.items():
        if "api" not in obj:
            continue
        cursor = tree
        parts = key.split(".")
        for part in parts[:-1]:
            cursor = cursor.setdefault(part, OrderedDict())
        cursor[parts[-1]] = obj["api"]
    return tree


def flatten_raw_endpoints(spec: dict) -> OrderedDict:
    endpoints = OrderedDict()
    for path, value in walk_api(spec["raw"]["describe"]["api"]):
        key = ".".join(path)
        endpoints[key] = OrderedDict(api=value)
    for key, cost in spec["rate_limits"]["per_endpoint_cost"].items():
        endpoints.setdefault(key, OrderedDict())["rate_limit"] = cost
    return endpoints


def method_object(spec: dict, method: str, shared_keys: set[str] | None) -> OrderedDict:
    obj = OrderedDict()
    obj["unified"] = spec["endpoints"]["unified"][method]
    has = spec["capabilities"]["has"].get(method)
    if has is not None:
        obj["has"] = has
    obj["mapping_complete"] = spec["capabilities"]["mapping_complete"][method]
    obj["verification"] = spec["capabilities"]["verification"][method]
    descriptor = spec["endpoints"]["descriptors"].get(method)
    if descriptor is not None:
        if shared_keys is not None and method in shared_keys:
            obj["descriptor"] = OrderedDict({"$ref": f"binance_family#{method}"})
        else:
            obj["descriptor"] = descriptor
    request = OrderedDict()
    defaults = spec["endpoints"]["request"]["defaults"].get(method)
    if defaults is not None:
        request["defaults"] = defaults
    selection = spec["endpoints"]["request"].get("endpoint_selection") or {}
    if method in selection:
        request["endpoint_selection"] = selection[method]
    if request:
        obj["request"] = request
    parse = spec["endpoints"]["handlers"]["parse"].get(method)
    if parse is not None:
        obj["parse"] = parse
    classification = spec["endpoints"]["transaction_classification"].get(method)
    if classification is not None:
        obj["transaction_classification"] = classification
    return obj


def split_venue(spec: dict, venue: str, shared_keys: set[str] | None) -> dict[str, object]:
    unified = spec["endpoints"]["unified"]
    has_extras = OrderedDict(
        (key, value)
        for key, value in spec["capabilities"]["has"].items()
        if key not in unified
    )
    parse_helpers = OrderedDict(
        (key, value)
        for key, value in spec["endpoints"]["handlers"]["parse"].items()
        if key not in unified
    )
    request_extras = OrderedDict(
        (key, value)
        for key, value in spec["endpoints"]["request"]["defaults"].items()
        if key not in unified
    )
    descriptor_extras = OrderedDict(
        (key, value)
        for key, value in spec["endpoints"]["descriptors"].items()
        if key not in unified
    )
    classification_extras = OrderedDict(
        (key, value)
        for key, value in spec["endpoints"]["transaction_classification"].items()
        if key not in unified
    )
    describe = OrderedDict(
        (key, value) for key, value in spec["raw"]["describe"].items() if key != "api"
    )
    venue_doc = OrderedDict()
    for key in VENUE_TOP:
        if key in spec:
            venue_doc[key] = spec[key]
    venue_doc["capabilities"] = OrderedDict(
        features=spec["capabilities"]["features"],
        timeframes=spec["capabilities"]["timeframes"],
        unsupported_raw_endpoints=spec["capabilities"]["unsupported_raw_endpoints"],
        has_extras=has_extras,
    )
    venue_doc["rate_limits"] = OrderedDict(
        buckets=spec["rate_limits"]["buckets"],
        endpoint_cost_binding=spec["rate_limits"]["endpoint_cost_binding"],
    )
    venue_doc["parse_helpers"] = parse_helpers
    venue_doc["request_extras"] = request_extras
    venue_doc["descriptor_extras"] = descriptor_extras
    venue_doc["classification_extras"] = classification_extras
    venue_doc["error_handlers"] = spec["endpoints"]["handlers"]["error"]
    venue_doc["signing_handlers"] = spec["endpoints"]["handlers"]["signing"]
    venue_doc["has_endpoint_selection"] = "endpoint_selection" in spec["endpoints"]["request"]

    endpoints = OrderedDict(
        (method, method_object(spec, method, shared_keys)) for method in unified
    )
    raw = OrderedDict(
        url_templates=spec["raw"]["url_templates"],
        describe=describe,
        request_shape=spec["endpoints"]["request"]["shape"],
        endpoints=flatten_raw_endpoints(spec),
    )
    return {
        "venue.json": venue_doc,
        "markets.json": spec["markets"],
        "errors.json": spec["errors"],
        "normalization.json": spec["normalization"],
        "endpoints.json": endpoints,
        "raw.json": raw,
    }


def build_request(defaults, selection, shape, has_endpoint_selection) -> OrderedDict:
    request = OrderedDict(defaults=defaults)
    if has_endpoint_selection:
        request["endpoint_selection"] = selection
    request["shape"] = shape
    return request


def assemble(files: dict[str, object], shared_descriptors: dict | None) -> OrderedDict:
    venue = files["venue.json"]
    endpoints = files["endpoints.json"]
    raw = files["raw.json"]
    unified = OrderedDict()
    descriptors = OrderedDict(venue.get("descriptor_extras") or {})
    defaults = OrderedDict(venue["request_extras"])
    selection = OrderedDict()
    parse = OrderedDict(venue["parse_helpers"])
    classification = OrderedDict(venue.get("classification_extras") or {})
    has = OrderedDict(venue["capabilities"]["has_extras"])
    mapping_complete = OrderedDict()
    verification = OrderedDict()

    for method, obj in endpoints.items():
        unified[method] = obj["unified"]
        if "has" in obj:
            has[method] = obj["has"]
        mapping_complete[method] = obj["mapping_complete"]
        verification[method] = obj["verification"]
        descriptor = obj.get("descriptor")
        if isinstance(descriptor, dict) and "$ref" in descriptor:
            _, key = descriptor["$ref"].split("#", 1)
            descriptors[method] = shared_descriptors[key]
        elif descriptor is not None:
            descriptors[method] = descriptor
        request = obj.get("request") or {}
        if "defaults" in request:
            defaults[method] = request["defaults"]
        if "endpoint_selection" in request:
            selection[method] = request["endpoint_selection"]
        if "parse" in obj:
            parse[method] = obj["parse"]
        if "transaction_classification" in obj:
            classification[method] = obj["transaction_classification"]

    pec = OrderedDict()
    for key, obj in raw["endpoints"].items():
        if "rate_limit" in obj:
            pec[key] = obj["rate_limit"]

    spec = OrderedDict()
    spec["auth"] = venue["auth"]
    spec["authored"] = venue["authored"]
    spec["capabilities"] = OrderedDict(
        features=venue["capabilities"]["features"],
        has=has,
        timeframes=venue["capabilities"]["timeframes"],
        unsupported_raw_endpoints=venue["capabilities"]["unsupported_raw_endpoints"],
        mapping_complete=mapping_complete,
        verification=verification,
    )
    spec["config"] = venue["config"]
    spec["endpoints"] = OrderedDict(
        descriptors=descriptors,
        handlers=OrderedDict(
            error=venue["error_handlers"],
            parse=parse,
            signing=venue["signing_handlers"],
        ),
        request=build_request(defaults, selection, raw["request_shape"], venue.get("has_endpoint_selection", True)),
        transaction_classification=classification,
        unified=unified,
    )
    spec["errors"] = files["errors.json"]
    spec["exchange"] = venue["exchange"]
    spec["fees"] = venue["fees"]
    spec["frozen"] = venue["frozen"]
    spec["hand_owned"] = venue["hand_owned"]
    spec["markets"] = files["markets.json"]
    spec["normalization"] = files["normalization.json"]
    spec["rate_limits"] = OrderedDict(
        buckets=venue["rate_limits"]["buckets"],
        endpoint_cost_binding=venue["rate_limits"]["endpoint_cost_binding"],
        per_endpoint_cost=pec,
    )
    describe = OrderedDict(raw["describe"])
    describe["api"] = unflatten_api(raw["endpoints"])
    spec["raw"] = OrderedDict(describe=describe, url_templates=raw["url_templates"])
    spec["schema_version"] = venue["schema_version"]
    spec["testnet"] = venue["testnet"]
    spec["urls"] = venue["urls"]
    spec["websocket"] = venue["websocket"]
    spec["emulated_methods"] = venue["emulated_methods"]
    return spec


def canonical(value) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def digest(value) -> str:
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def family_shared_keys(specs: dict[str, dict]) -> set[str]:
    descriptors = {venue: spec["endpoints"]["descriptors"] for venue, spec in specs.items()}
    shared = set()
    keys = set().union(*(set(d) for d in descriptors.values()))
    for key in keys:
        present = [venue for venue in BINANCE_FAMILY if key in descriptors[venue]]
        if len(present) < 2:
            continue
        first = descriptors[present[0]][key]
        if all(descriptors[venue][key] == first for venue in present):
            shared.add(key)
    return shared


def main() -> None:
    venues = sorted(
        path.parent.parent.name
        for path in ROOT.glob("*/authored/spec.json")
    )
    originals = {venue: load_json(ROOT / venue / "authored" / "spec.json") for venue in venues}

    before_bytes = {
        venue: (ROOT / venue / "authored" / "spec.json").stat().st_size for venue in venues
    }
    family_specs = {venue: originals[venue] for venue in BINANCE_FAMILY}
    shared_keys = family_shared_keys(family_specs)
    shared_descriptors = OrderedDict()
    for key in sorted(shared_keys):
        for venue in BINANCE_FAMILY:
            if key in family_specs[venue]["endpoints"]["descriptors"]:
                shared_descriptors[key] = family_specs[venue]["endpoints"]["descriptors"][key]
                break

    dump_json(SHARED, shared_descriptors)

    hashes = OrderedDict()
    for venue, spec in originals.items():
        hashes[venue] = digest(spec)
        files = split_venue(
            spec, venue, shared_keys if venue in BINANCE_FAMILY else None
        )
        authored = ROOT / venue / "authored"
        for name, value in files.items():
            dump_json(authored / name, value)
        assembled = assemble(
            {name: load_json(authored / name) for name in files},
            shared_descriptors if venue in BINANCE_FAMILY else None,
        )
        if canonical(assembled) != canonical(spec):
            raise SystemExit(f"roundtrip mismatch for {venue}")

    after_bytes = OrderedDict()
    for venue in venues:
        authored = ROOT / venue / "authored"
        after_bytes[venue] = sum(
            path.stat().st_size for path in authored.glob("*.json")
        )
    shared_size = SHARED.stat().st_size
    family_before = sum(before_bytes[v] for v in BINANCE_FAMILY)
    family_after = sum(after_bytes[v] for v in BINANCE_FAMILY) + shared_size

    report = ROOT / "_shared" / "binance_family" / "rotation_report.json"
    dump_json(
        report,
        OrderedDict(
            before_bytes=before_bytes,
            after_bytes=after_bytes,
            shared_descriptors_bytes=shared_size,
            shared_descriptor_keys=len(shared_keys),
            family_before_bytes=family_before,
            family_after_bytes=family_after,
            hashes=hashes,
        ),
    )
    print("venues", len(venues))
    print("shared_descriptor_keys", len(shared_keys))
    print("family_before_bytes", family_before)
    print("family_after_bytes", family_after)
    print("hashes")
    for venue, value in hashes.items():
        print(f"  {venue} {value}")


if __name__ == "__main__":
    main()
