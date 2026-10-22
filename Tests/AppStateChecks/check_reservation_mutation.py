#!/usr/bin/env python3
"""Compile the real reservation mutation store and run its state probe."""
from pathlib import Path
import os
import subprocess


root = Path(__file__).resolve().parents[2]
build = Path(os.environ.get("APP_STATE_CHECK_BUILD_DIR", root / ".build/app-state-checks"))
build.mkdir(parents=True, exist_ok=True)

sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()

swiftpm_build = Path(os.environ.get("RINGONOMITV_SWIFTPM_BUILD_DIR", root / ".build"))
artifacts = []
for module in swiftpm_build.rglob("RingonomiCore.swiftmodule"):
    # Do not accidentally reuse a stale probe-local build directory from a
    # previous invocation; the source of truth is the preceding SwiftPM test.
    if build in module.parents:
        continue
    module_dir = module.parent
    configuration_dir = module_dir.parent
    object_dir = configuration_dir / "RingonomiCore.build"
    objects = sorted(object_dir.glob("*.o"))
    if objects:
        artifacts.append((module, configuration_dir, objects))
if not artifacts:
    raise SystemExit(
        "RingonomiCore build artifacts were not found. Run ./test.sh first "
        "so the probe can reuse its Modules and RingonomiCore.build/*.o files."
    )

# Reuse the Core module and object files produced by the preceding SwiftPM
# test job. This avoids a second full Core compilation and does not assume an
# automatic SwiftPM library archive exists.
module, configuration_dir, objects = artifacts[0]
module_dir = module.parent
target_platform = configuration_dir.parent.name
target_architecture = target_platform.split("-", 1)[0]
binary = build / "reservation-mutation-check"
subprocess.run(
    [
        compiler, "-parse-as-library", "-swift-version", "6",
        "-strict-concurrency=complete", "-sdk", sdk,
        "-target", target_architecture + "-apple-macosx14.0",
        "-module-cache-path", str(build / "module-cache"),
        "-I", str(module_dir),
        str(root / "App/ReservationMutationJournalKeychain.swift"),
        str(root / "App/RingonomiMutationStore.swift"),
        str(root / "Tests/AppStateChecks/ReservationMutationCheck.swift"),
        *map(str, objects),
        "-o", str(binary),
    ],
    check=True,
)
subprocess.run([str(binary)], check=True)
