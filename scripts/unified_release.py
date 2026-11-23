#!/usr/bin/env python3
"""Verify three immutable client artifacts before publishing one complete draft."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
from urllib.error import HTTPError
from urllib.parse import quote, urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener
import zipfile

import macos_release_validation as mac
from release_identity import repository_identity

require = mac.require
IDENTITY = repository_identity()
ABIS = {"arm64-v8a", "armeabi-v7a", "x86_64"}
MANIFEST = "release-manifest.json"


def names(platform):
    if platform == "android":
        package = f"fanqie-v{IDENTITY.version}.apk"
    elif platform == "windows":
        package = f"FanqieReader-{IDENTITY.version}-{IDENTITY.build}-windows-x64.zip"
    elif platform == "macos":
        package = mac.NAME
    else:
        raise mac.ValidationError(f"Unknown client: {platform}")
    return package, package + ".sha256", f"{platform}-build-info.json"


def real_files(directory, expected):
    directory = Path(directory)
    require(directory.is_dir() and not directory.is_symlink(), "Expected a real artifact directory")
    actual = list(directory.iterdir())
    require({p.name for p in actual} == set(expected), "Missing/extra platform artifacts")
    require(all(p.is_file() and not p.is_symlink() and p.stat().st_size > 0 for p in actual),
            "Empty/non-file/symlink artifact")


def common(info, trigger):
    require(isinstance(info, dict), "Invalid client provenance")
    for key in mac.TRIGGER_KEYS:
        require(info.get(key) == trigger[key], f"Client source/run mismatch: {key}")
    for key, value in {
        "schema_version": 1, "version": IDENTITY.full_version,
        "release_tag": IDENTITY.tag, "build_target": "lib/main.dart", "build_mode": "Release",
    }.items():
        require(type(info.get(key)) is type(value) and info[key] == value, f"Wrong client {key}")
    mac.validate_sdk(info.get("flutter"))
    require(info["flutter"].get("channel") == "stable", "Expected the pinned stable SDK")


def checksums(directory, info, field, package):
    records = info.get(field)
    expected = {package, package + ".sha256"}
    require(isinstance(records, dict) and set(records) == expected, "Wrong client asset manifest")
    for name in expected:
        require(records[name] == mac.record(Path(directory) / name), f"Client asset changed: {name}")
    sidecar = f"{records[package]['sha256']}  {package}\n".encode("ascii")
    require((Path(directory) / (package + ".sha256")).read_bytes() == sidecar,
            "Invalid exact checksum sidecar")


def zip_files(archive):
    seen = set()
    total = 0
    files = []
    require(len(archive.infolist()) <= 10000, "Unbounded ZIP entry count")
    for entry in archive.infolist():
        name = entry.filename.rstrip("/") if entry.is_dir() else entry.filename
        mac.relative_path(name)
        require(name.casefold() not in seen, "Duplicate/aliased archive path")
        seen.add(name.casefold())
        require(stat.S_IFMT(entry.external_attr >> 16) != stat.S_IFLNK, "Archive symlink is forbidden")
        require(not (entry.flag_bits & 1), "Encrypted archive is forbidden")
        total += entry.file_size
        require(total <= 2 * 1024**3, "Unbounded inflated archive")
        if not entry.is_dir():
            files.append(entry)
    return files


def android_payload(apk):
    try:
        with zipfile.ZipFile(apk) as archive:
            entries = {entry.filename: entry for entry in zip_files(archive)}
            for name in ["AndroidManifest.xml", "classes.dex", "resources.arsc",
                         "assets/flutter_assets/AssetManifest.bin",
                         "assets/flutter_assets/FontManifest.json"]:
                require(name in entries and entries[name].file_size > 0, f"Missing APK resource: {name}")
            abis = {
                name.split("/")[1] for name in entries
                if re.fullmatch(r"lib/[^/]+/libapp\.so", name)
            }
            require(abis == ABIS, "Universal production APK must contain all three AOT ABIs")
            for abi in abis:
                for library in ["libapp.so", "libflutter.so"]:
                    name = f"lib/{abi}/{library}"
                    require(name in entries and entries[name].file_size > 0, f"Missing AOT library: {name}")
            require(archive.testzip() is None, "APK CRC failed")
            return sorted(abis)
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        raise mac.ValidationError(f"Invalid APK: {error}") from error


def validate_windows(directory, trigger):
    package, checksum, metadata = names("windows")
    real_files(directory, [package, checksum, metadata])
    info = mac.read_json(Path(directory) / metadata)
    common(info, trigger)
    require(info.get("architecture") == "x64" and info.get("signing") == "unsigned"
            and info.get("authenticode_signed") is False
            and info.get("runtime", {}).get("family") == "VC143", "Wrong Windows runtime/signing")
    checksums(directory, info, "assets", package)
    payload = info.get("package_files_sha256")
    require(isinstance(payload, dict) and "FanqieReader.exe" in payload
            and "flutter_windows.dll" in payload, "Missing Windows production payload")
    try:
        with zipfile.ZipFile(Path(directory) / package) as archive:
            entries = zip_files(archive)
            require({entry.filename for entry in entries} == set(payload), "ZIP payload count/path mismatch")
            for entry in entries:
                with archive.open(entry) as stream:
                    actual = hashlib.file_digest(stream, "sha256").hexdigest()
                require(payload[entry.filename] == actual, f"Windows ZIP payload changed: {entry.filename}")
    except (OSError, zipfile.BadZipFile) as error:
        raise mac.ValidationError(f"Invalid Windows ZIP: {error}") from error
    return info


def validate_android(directory, trigger):
    package, checksum, metadata = names("android")
    real_files(directory, [package, checksum, metadata])
    info = mac.read_json(Path(directory) / metadata)
    common(info, trigger)
    require(info.get("build") == IDENTITY.build and info.get("architecture") == "universal"
            and info.get("application_id") == "com.fanqie.fanqie_flutter"
            and info.get("signing") == "release-keystore" and info.get("signed") is True,
            "Wrong Android identity or non-release signing")
    require(isinstance(info.get("signing_certificate_sha256"), str)
            and re.fullmatch("[0-9a-f]{64}", info["signing_certificate_sha256"]),
            "Missing verified Android signer")
    checksums(directory, info, "assets", package)
    require(info.get("native_abis") == android_payload(Path(directory) / package), "Wrong APK ABI evidence")
    return info


def client_summary(platform, info):
    result = {
        "package": names(platform)[0], "architecture": info["architecture"],
        "signing": info["signing"], "build_target": info["build_target"],
    }
    if platform == "macos":
        result["notarized"] = info["notarized"]
    return result


def assemble(android, windows, macos, output, trigger):
    mac.validate_trigger(trigger)
    inputs = {"android": Path(android), "windows": Path(windows), "macos": Path(macos)}
    info = {
        "android": validate_android(android, trigger),
        "windows": validate_windows(windows, trigger),
        "macos": mac.validate_artifacts(macos, trigger),
    }
    # mac.validate_artifacts returns the validated build-info mapping.
    output = Path(output)
    require(not output.exists() and not output.is_symlink(), "No overwrite: release output exists")
    output.mkdir(parents=True)
    assets = {}
    for platform, directory in inputs.items():
        for name in names(platform):
            source = directory / ("build-info.json" if platform == "macos" and name.endswith(".json") else name)
            shutil.copyfile(source, output / name)
            assets[name] = mac.record(output / name)
    manifest = {
        **{key: trigger[key] for key in mac.TRIGGER_KEYS}, "schema_version": 1,
        "version": IDENTITY.full_version, "release_tag": IDENTITY.tag,
        "platforms": {platform: client_summary(platform, data) for platform, data in info.items()},
        "assets": assets,
    }
    (output / MANIFEST).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    validate_stage(output, trigger)


def validate_stage(directory, trigger):
    mac.validate_trigger(trigger)
    expected = {MANIFEST} | {name for platform in ["android", "windows", "macos"] for name in names(platform)}
    real_files(directory, expected)
    manifest = mac.read_json(Path(directory) / MANIFEST)
    for key in mac.TRIGGER_KEYS:
        require(manifest.get(key) == trigger[key], f"Release source/run mismatch: {key}")
    require(type(manifest.get("schema_version")) is int and manifest["schema_version"] == 1
            and manifest.get("version") == IDENTITY.full_version
            and manifest.get("release_tag") == IDENTITY.tag, "Wrong release identity")
    assets = manifest.get("assets")
    require(isinstance(assets, dict) and set(assets) == expected - {MANIFEST}, "Wrong complete asset set")
    for name in assets:
        require(assets[name] == mac.record(Path(directory) / name), f"Release artifact changed: {name}")
    # Independent native validators retain their exact three-file inputs. The
    # temporary views are copies, never symlinks or extraction/execution.
    with tempfile.TemporaryDirectory(prefix="unified-verify-") as temporary:
        roots = {}
        for platform in ["android", "windows", "macos"]:
            root = Path(temporary) / platform
            root.mkdir()
            roots[platform] = root
            for name in names(platform):
                destination = "build-info.json" if platform == "macos" and name.endswith(".json") else name
                shutil.copyfile(Path(directory) / name, root / destination)
        infos = {
            "android": validate_android(roots["android"], trigger),
            "windows": validate_windows(roots["windows"], trigger),
            "macos": mac.validate_artifacts(roots["macos"], trigger),
        }
    require(manifest.get("platforms") == {
        platform: client_summary(platform, info) for platform, info in infos.items()
    }, "Platform coverage/signing claims differ from verified evidence")
    return {name: mac.record(Path(directory) / name) for name in expected}


class GitHubApi:
    def __init__(self, token):
        require(bool(token), "GitHub publication token is required")
        self.token = token

    def request(self, method, path, *, body=None, file=None, expected=200):
        url = path if path.startswith("https://") else "https://api.github.com" + path
        require(urlparse(url).hostname in {"api.github.com", "uploads.github.com"}, "Unexpected API host")
        data = None
        content_type = "application/json"
        if body is not None:
            data = json.dumps(body).encode("utf-8")
        elif file is not None:
            data = Path(file).read_bytes()
            content_type = "application/octet-stream"
        request = Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "Content-Type": content_type,
        })
        class NoRedirect(HTTPRedirectHandler):
            def redirect_request(self, request, fp, code, message, headers, url):
                # Never forward a publication token/body to a redirect target.
                return None

        try:
            response = build_opener(NoRedirect()).open(request, timeout=120)
        except HTTPError as error:
            if error.code == expected:
                return None
            raise mac.ValidationError(f"GitHub {method} failed: HTTP {error.code}, expected {expected}") from error
        with response:
            require(response.status == expected, f"Unexpected API status: {response.status}")
            payload = response.read()
            return json.loads(payload) if payload else None


def tag_commit(api, base, ref):
    obj = ref.get("object", {})
    seen = set()
    for _ in range(10):
        require(isinstance(obj.get("sha"), str) and re.fullmatch("[0-9a-f]{40}", obj["sha"]),
                "Invalid remote tag SHA")
        if obj.get("type") == "commit":
            return obj["sha"]
        require(obj.get("type") == "tag" and obj["sha"] not in seen, "Invalid/cyclic remote tag")
        seen.add(obj["sha"])
        obj = api.request("GET", f"{base}/git/tags/{obj['sha']}").get("object", {})
    raise mac.ValidationError("Remote tag chain is too deep")


def publish(api, directory, trigger, repository, notes):
    require(trigger.get("source_ref") in {"refs/heads/main", f"refs/tags/{IDENTITY.tag}"},
            "Only main or its exact release tag may publish")
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository), "Invalid repository")
    files = validate_stage(directory, trigger)
    base = f"/repos/{repository}"
    refs = api.request("GET", f"{base}/git/matching-refs/tags/{IDENTITY.tag}")
    require(isinstance(refs, list), "Invalid tag collision response")
    existing = [ref for ref in refs if ref.get("ref") == f"refs/tags/{IDENTITY.tag}"]
    tagged_input = trigger["source_ref"] == f"refs/tags/{IDENTITY.tag}"
    if tagged_input:
        require(len(existing) == 1 and tag_commit(api, base, existing[0]) == trigger["source_commit"],
                "Triggering tag is missing or points at another source")
    else:
        require(not existing, "Tag already exists; no force/reuse")
    api.request("GET", f"{base}/releases/tags/{IDENTITY.tag}", expected=404)
    for page in range(1, 21):
        releases = api.request("GET", f"{base}/releases?per_page=100&page={page}")
        require(isinstance(releases, list), "Invalid release collision response")
        require(not any(item.get("tag_name") == IDENTITY.tag for item in releases),
                "Release/draft already exists; no overwrite/reuse")
        if len(releases) < 100:
            break
    else:
        raise mac.ValidationError("Release collision scan limit exceeded")
    if not tagged_input:
        created = api.request("POST", f"{base}/git/refs", body={
            "ref": f"refs/tags/{IDENTITY.tag}", "sha": trigger["source_commit"],
        }, expected=201)
        require(tag_commit(api, base, created) == trigger["source_commit"], "Created tag source mismatch")
    draft = api.request("POST", f"{base}/releases", body={
        "tag_name": IDENTITY.tag, "target_commitish": trigger["source_commit"],
        "name": f"番茄Reader {IDENTITY.tag} · Android / Windows / macOS",
        "body": notes, "draft": True, "prerelease": False, "make_latest": "false",
    }, expected=201)
    release_id = draft.get("id")
    require(type(release_id) is int and release_id > 0 and draft.get("draft") is True
            and draft.get("tag_name") == IDENTITY.tag
            and draft.get("target_commitish") == trigger["source_commit"], "Unexpected new draft identity")
    upload = draft.get("upload_url", "").split("{", 1)[0]
    require(urlparse(upload).scheme == "https" and urlparse(upload).hostname == "uploads.github.com",
            "Unexpected upload host")
    for name in sorted(files):
        api.request("POST", f"{upload}?name={quote(name, safe='')}",
                    file=Path(directory) / name, expected=201)

    def confirm(value, is_draft):
        require(value.get("id") == release_id and value.get("tag_name") == IDENTITY.tag
                and value.get("target_commitish") == trigger["source_commit"]
                and value.get("draft") is is_draft and value.get("prerelease") is False,
                "Remote release identity/state differs")
        assets = value.get("assets")
        require(isinstance(assets, list) and len(assets) == len(files), "Incomplete remote release")
        for name, expected in files.items():
            matches = [asset for asset in assets if asset.get("name") == name]
            require(len(matches) == 1 and matches[0].get("state") == "uploaded"
                    and matches[0].get("size") == expected["size"]
                    and matches[0].get("digest") == f"sha256:{expected['sha256']}",
                    f"Remote asset digest/state/size mismatch: {name}")
        ref = api.request("GET", f"{base}/git/ref/tags/{IDENTITY.tag}")
        require(tag_commit(api, base, ref) == trigger["source_commit"], "Remote tag source changed")

    confirm(api.request("GET", f"{base}/releases/{release_id}"), True)
    result = api.request("PATCH", f"{base}/releases/{release_id}", body={
        "draft": False, "prerelease": False, "make_latest": "true",
    })
    confirm(result, False)
    confirm(api.request("GET", f"{base}/releases/{release_id}"), False)
    return result


def signing_certificate(report, expected):
    require(re.fullmatch("[0-9a-f]{64}", expected.lower()), "Invalid configured certificate digest")
    counts = re.findall(r"^Number of signers:\s*([0-9]+)\s*$", report, re.MULTILINE)
    require(counts == ["1"], "Expected exactly one real APK signer")
    require(re.search(r"^Verified using v2 scheme \(APK Signature Scheme v2\): true\s*$",
                      report, re.MULTILINE), "APK v2 signature did not verify")
    # Recent Android build-tools report V2/V3 Signer sections instead of the
    # older Signer #1 prefix. Multiple schemes must all bind the same cert;
    # public-key digests and source-stamp signers are not certificate evidence.
    digests = re.findall(
        r"^(?:Signer #[0-9]+|V[1-4](?:\.[0-9]+)? Signer:)\s+"
        r"certificate SHA-256 digest:\s*([0-9a-fA-F]{64})\s*$",
        report, re.MULTILINE,
    )
    require(bool(digests) and {digest.lower() for digest in digests} == {expected.lower()},
            "APK is not signed with the configured release certificate")
    return expected.lower()


def create_android(args, trigger):
    sdk = mac.read_json(args.sdk)
    mac.validate_sdk(sdk)
    require(sdk.get("channel") == "stable", "Wrong Android SDK channel")
    badging = args.badging.read_text()
    package = re.search(r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'",
                        badging, re.MULTILINE)
    require(package and package.groups() == (
        "com.fanqie.fanqie_flutter", IDENTITY.build, IDENTITY.version,
    ), "APK package/versionCode/versionName differs from pubspec")
    certificate = signing_certificate(args.signature.read_text(), args.certificate_sha256)
    abis = android_payload(args.apk)
    require(not args.output.exists() and not args.output.is_symlink(), "No overwrite: Android output")
    args.output.mkdir(parents=True)
    name, sidecar, metadata = names("android")
    shutil.copyfile(args.apk, args.output / name)
    (args.output / sidecar).write_text(f"{mac.digest(args.output / name)}  {name}\n", encoding="ascii")
    info = {
        **{key: trigger[key] for key in mac.TRIGGER_KEYS},
        "schema_version": 1, "version": IDENTITY.full_version, "build": IDENTITY.build,
        "release_tag": IDENTITY.tag, "architecture": "universal", "build_mode": "Release",
        "build_target": "lib/main.dart", "application_id": "com.fanqie.fanqie_flutter",
        "signing": "release-keystore", "signed": True, "native_abis": abis, "flutter": sdk,
        "signing_certificate_sha256": certificate,
        "assets": {n: mac.record(args.output / n) for n in [name, sidecar]},
    }
    (args.output / metadata).write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    validate_android(args.output, trigger)


def prepare(requested, publish_input):
    trigger = mac.environment_trigger()
    require(not requested or requested == IDENTITY.version, "Requested version differs from pubspec")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    require(head == trigger["source_commit"], "Checkout differs from triggering SHA")
    tagged = trigger["source_ref"].startswith("refs/tags/")
    require(not tagged or trigger["source_ref"] == f"refs/tags/{IDENTITY.tag}", "Tag differs from pubspec")
    publish_requested = tagged or publish_input == "true"
    if publish_requested:
        require(trigger["source_ref"] in {"refs/heads/main", f"refs/tags/{IDENTITY.tag}"},
                "Only main and its exact release tag may publish")
        subprocess.run(["git", "fetch", "--no-tags", "origin",
                        "+refs/heads/main:refs/remotes/origin/main"], check=True)
        result = subprocess.run(["git", "merge-base", "--is-ancestor", head, "origin/main"])
        require(result.returncode == 0, "Release source must be reachable from main")
    packages = tagged or os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
    values = {
        "version": IDENTITY.version, "build": IDENTITY.build,
        "full_version": IDENTITY.full_version, "release_tag": IDENTITY.tag,
        "publish": str(publish_requested).lower(), "packages": str(packages).lower(),
        "android_artifact": f"android-{IDENTITY.version}-{IDENTITY.build}-{trigger['run_id']}-{trigger['run_attempt']}",
        "combined_artifact": f"unified-{IDENTITY.version}-{IDENTITY.build}-{trigger['run_id']}-{trigger['run_attempt']}",
    }
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("prepare")
    p.add_argument("--version", default="")
    p.add_argument("--publish", choices=["true", "false"], default="false")
    p = commands.add_parser("android")
    for name in ["apk", "sdk", "badging", "signature", "output"]:
        p.add_argument("--" + name, type=Path, required=True)
    p.add_argument("--certificate-sha256", required=True)
    p = commands.add_parser("assemble")
    for name in ["android", "windows", "macos", "output"]:
        p.add_argument("--" + name, type=Path, required=True)
    for name in ["verify", "publish"]:
        p = commands.add_parser(name)
        p.add_argument("directory", type=Path)
        if name == "publish":
            p.add_argument("--notes", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.version, args.publish)
        return
    trigger = mac.environment_trigger()
    if args.command == "android":
        create_android(args, trigger)
    elif args.command == "assemble":
        assemble(args.android, args.windows, args.macos, args.output, trigger)
    elif args.command == "verify":
        validate_stage(args.directory, trigger)
    else:
        result = publish(GitHubApi(os.environ.get("GH_TOKEN")), args.directory, trigger,
                         os.environ["GITHUB_REPOSITORY"], args.notes.read_text(encoding="utf-8"))
        print(result.get("html_url", f"Published {IDENTITY.tag}"))
    print(f"Verified {args.command}: all three clients at {IDENTITY.full_version}")


if __name__ == "__main__":
    main()
