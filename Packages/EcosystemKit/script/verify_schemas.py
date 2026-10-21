#!/usr/bin/env python3
"""Проверяет схемы/роли и реальные Swift-encoded фикстуры независимым validator."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Sources/EcosystemContracts/Resources"


def load(path: Path) -> Any:
    """Все документы локальные; validator не загружает схемы из сети."""
    return json.loads(path.read_text())


def main() -> None:
    """Схемы проверяют структуру; временные/межполевые условия покрывает XCTest."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift-samples", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    contracts = load(RESOURCES / "Schemas/contracts.schema.json")
    registry = Registry().with_resource(
        contracts["$id"], Resource.from_contents(contracts)
    )
    schemas = {
        path.name: load(path)
        for path in (RESOURCES / "Schemas").glob("*.json")
    }
    for schema in schemas.values():
        Draft202012Validator.check_schema(schema)
    count = 0
    for name in contracts["$defs"]:
        sample = args.swift_samples / (name + ".json")
        if not sample.is_file():
            if name == "ContractVersion":
                continue
            raise RuntimeError("Swift sample missing: " + name)
        selected = {"$ref": "#/$defs/" + name, "$defs": contracts["$defs"]}
        Draft202012Validator(
            selected, format_checker=FormatChecker()
        ).validate(load(sample))
        count += 1
    role_validator = Draft202012Validator(schemas["role.schema.json"])
    capability_registry = load(RESOURCES / "capability-registry.json")
    Draft202012Validator(
        schemas["registry.schema.json"],
        registry=registry,
        format_checker=FormatChecker(),
    ).validate(capability_registry)
    capabilities = {
        (item["agentId"], item["id"])
        for item in capability_registry["capabilities"]
    }
    roles = list((RESOURCES / "Roles").glob("*.json"))
    for path in roles:
        role = load(path)
        role_validator.validate(role)
        if not (path.parent / role["instructionFile"]).is_file():
            raise RuntimeError("Instruction file missing")
        for agent in role["allowedAgentIds"]:
            for capability in role["allowedCapabilities"]:
                if (agent, capability) not in capabilities:
                    raise RuntimeError("Role names an unknown capability")
    task = load(args.swift_samples / "TaskRequest.json")
    validator = Draft202012Validator(
        {"$ref": "#/$defs/TaskRequest", "$defs": contracts["$defs"]},
        format_checker=FormatChecker(),
    )
    cases: list[dict[str, Any]] = []
    for name, value in [
        ("approved", True),
        ("schemaVersion", {"major": 2}),
        ("createdAt", "2026-02-30T12:00:00Z"),
        ("requestId", "not-a-uuid"),
    ]:
        case = copy.deepcopy(task)
        case[name] = value
        cases.append(case)
    nested = copy.deepcopy(task)
    nested["clientContext"] = {"clientId": "hermes-future", "verified": True}
    cases.append(nested)
    file_case = copy.deepcopy(task)
    file_case.update({"agentId": "ares", "capabilityId": "file.scan"})
    cases.append(file_case)
    for case in cases:
        if validator.is_valid(case):
            raise RuntimeError("Invalid task accepted by schema")
    report = {
        "schemas": len(schemas),
        "swiftEncodedSamples": count,
        "roles": len(roles),
        "registryEntries": len(capabilities),
        "negativeSchemaCases": len(cases),
        "networkSchemaFetches": 0,
        "allPassed": True,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
