#!/usr/bin/env python3
"""Exercise proposed SDK public-API path layout with real public sources.

The SDK is a dependency-resolution fixture, not media code or a native binary.
All pub operations are offline in disposable directories; source worktrees stay
untouched. This is not configure_media_sdk.ps1 or formal SDK acceptance.
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import unquote, urljoin, urlparse


PACKAGES = ("share_hub_media_api", "share_hub_session_api", "share_hub_connection")
SDK_SPEC = """name: share_hub_media_sdk
version: 0.1.0-layout-example.1
publish_to: none
environment:
  sdk: '>=3.13.2 <4.0.0'
  flutter: '>=3.47.2'
dependencies:
  flutter:
    sdk: flutter
  share_hub_media_api:
    path: public_api/share_hub_media_api
"""
CLIENT_SPEC = """name: sdk_layout_probe
version: 0.0.0
publish_to: none
environment:
  sdk: '>=3.13.2 <4.0.0'
  flutter: '>=3.47.2'
dependencies:
  flutter:
    sdk: flutter
  share_hub_media_sdk:
    path: '../SDK 目录'
  share_hub_media_api:
    path: ../public/share_hub_media_api
  share_hub_connection:
    path: ../public/share_hub_connection
"""
OVERRIDE = """
dependency_overrides:
  share_hub_media_api:
    path: ../public/share_hub_media_api
"""


def resolved_package(package_config, name):
    data = json.loads(package_config.read_text())
    entries = [p for p in data["packages"] if p["name"] == name]
    if len(entries) != 1:
        raise RuntimeError(f"Expected exactly one resolved {name}")
    uri = urlparse(urljoin(package_config.as_uri(), entries[0]["rootUri"]))
    if uri.scheme != "file" or uri.netloc:
        raise RuntimeError(f"Unexpected non-local package URI for {name}")
    path = unquote(uri.path)
    if len(path) >= 3 and path[0] == "/" and path[2] == ":":
        path = path[1:]
    return Path(path).resolve()


def run_pub(flutter, directory, succeeds=True):
    run = subprocess.run([flutter, "pub", "get", "--offline"], cwd=directory,
                         text=True, capture_output=True, timeout=120)
    output = run.stdout + run.stderr
    if succeeds and run.returncode:
        raise RuntimeError(f"Offline dependency resolution failed: {output[-4000:]}")
    if not succeeds:
        if run.returncode == 0 or not all(term in output for term in (
            "share_hub_media_api", "public_api", "version solving failed"
        )):
            raise RuntimeError(f"Expected duplicate-source resolution failure: {output[-4000:]}")
    return run.returncode


def check_roots(directory, expected):
    config = directory / ".dart_tool/package_config.json"
    for name, path in expected.items():
        if resolved_package(config, name) != path.resolve():
            raise RuntimeError(f"{name} resolved outside the expected public snapshot")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter", required=True, help="Flutter 3.47.2 executable")
    args = parser.parse_args()
    flutter = shutil.which(args.flutter)
    if flutter is None:
        parser.error("Flutter executable not found")
    flutter = str(Path(flutter).resolve())
    version = json.loads(subprocess.run([flutter, "--version", "--machine"],
                                       check=True, text=True, capture_output=True).stdout)
    if version.get("frameworkVersion") != "3.47.2" or version.get("dartSdkVersion", "").split()[0] != "3.13.2":
        parser.error("Use the project's pinned Flutter 3.47.2 / Dart 3.13.2")
    packages = Path(__file__).resolve().parents[2]
    snapshots = []
    checks = []
    with tempfile.TemporaryDirectory(prefix="sdk-layout-") as temporary:
        root = Path(temporary) / "原工作区 spaces"
        public = root / "public"
        sdk = root / "SDK 目录"
        client = root / "客户端"
        for name in PACKAGES:
            source = packages / name
            destination = public / name
            destination.mkdir(parents=True)
            shutil.copyfile(source / "pubspec.yaml", destination / "pubspec.yaml")
            shutil.copytree(source / "lib", destination / "lib")
            files = [destination / "pubspec.yaml", *sorted((destination / "lib").rglob("*.dart"))]
            entries = [{"path": p.relative_to(destination).as_posix(),
                        "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in files]
            sdk_version = re.search(r"(?m)^version:\s*(\S+)\s*$", (source / "pubspec.yaml").read_text()).group(1)
            snapshots.append({"package": name, "version": sdk_version, "files": len(entries),
                              "publicSourceDigest": hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest()})
        for name in PACKAGES[:2]:
            shutil.copytree(public / name, sdk / "public_api" / name)
        (sdk / "pubspec.yaml").write_text(SDK_SPEC)
        (sdk / "lib").mkdir()
        (sdk / "lib/share_hub_media_sdk.dart").write_text(
            "// Dependency-layout fixture only. No media implementation.\n"
            "export 'package:share_hub_media_api/share_hub_media_api.dart';\n")
        client.mkdir()
        (client / "pubspec.yaml").write_text(CLIENT_SPEC)
        run_pub(flutter, client, succeeds=False)
        checks.append("different-public-api-paths-rejected-without-override")
        (client / "pubspec.yaml").write_text(CLIENT_SPEC + OVERRIDE)
        run_pub(flutter, client)
        check_roots(client, {
            "share_hub_media_api": public / "share_hub_media_api",
            "share_hub_session_api": public / "share_hub_session_api",
            "share_hub_connection": public / "share_hub_connection",
            "share_hub_media_sdk": sdk,
        })
        checks.append("existing-client-media-override-selects-canonical-media-and-session-api")
        run_pub(flutter, sdk)
        check_roots(sdk, {name: sdk / "public_api" / name for name in PACKAGES[:2]})
        checks.append("standalone-sdk-layout-resolves-bundled-public-snapshots")
        moved = root.with_name("搬移后的目录 spaces")
        root.rename(moved)
        client = moved / "客户端"
        run_pub(flutter, client)
        check_roots(client, {
            "share_hub_media_api": moved / "public/share_hub_media_api",
            "share_hub_session_api": moved / "public/share_hub_session_api",
            "share_hub_media_sdk": moved / "SDK 目录",
        })
        checks.append("relocated-chinese-space-paths-remain-local-and-canonical")
    print(json.dumps({
        "scope": "Public API path/dependency resolution with an SDK fixture, not a real SDK binary or installer test.",
        "flutter": version["frameworkVersion"], "dart": version["dartSdkVersion"],
        "checks": checks, "publicSnapshots": snapshots,
        "offline": True, "privateSdkSourceRead": False, "sdkBinaryLoaded": False,
        "sourceWorktreesModified": False,
        "checkerSha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
