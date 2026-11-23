#!/usr/bin/env python3
"""Fail-closed stdlib validation for the pinned production Mac self-use package.

Portable resource/provenance checks do not replace native Mach-O, codesign or
read-only mounted-image checks. No network, user data or app execution here.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import sys

from release_identity import repository_identity

IDENTITY = repository_identity()
VERSION = IDENTITY.full_version
BUILD = IDENTITY.build
NAME = f"fanqie-v{IDENTITY.version}-{BUILD}-macos-arm64-internal.dmg"
FORMAL_NAME = f"fanqie-v{IDENTITY.version}-{BUILD}-macos-arm64.dmg"
ASSETS = "Contents/Frameworks/App.framework/Resources/flutter_assets"
ICU = "Contents/Frameworks/FlutterMacOS.framework/Resources/icudtl.dat"
FONTS = {
    "ReaderKaiTi": "assets/fonts/LXGWWenKaiLite-Regular.ttf",
    "ReaderSongTi": "assets/fonts/ZCOOLXiaoWei-Regular.ttf",
    "MaterialIcons": "fonts/MaterialIcons-Regular.otf",
    "packages/cupertino_icons/CupertinoIcons": "packages/cupertino_icons/assets/CupertinoIcons.ttf",
}
RESOURCES = [
    "AssetManifest.bin", "NOTICES.Z", "assets/icons/fanqie.png",
    "assets/fonts/LXGW-OFL.txt", "assets/fonts/ZCOOL-OFL.txt",
    "assets/data/font_map.json", "assets/data/reader_script_map.json",
    "assets/data/charset.json", "assets/data/lib_font_map.json",
]
ENTITLEMENTS = {
    "com.apple.security.app-sandbox",
    "com.apple.security.network.client",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.files.downloads.read-write",
    "com.apple.security.files.bookmarks.app-scope",
}
TRIGGER_KEYS = ("source_commit", "source_ref", "workflow_run", "run_id", "run_attempt")


class ValidationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def read_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f"Duplicate JSON key: {key}")
            result[key] = value
        return result
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"), object_pairs_hook=unique)
    except (OSError, ValueError) as error:
        raise ValidationError(f"Invalid JSON {path}: {error}") from error


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def record(path):
    return {"sha256": digest(path), "size": Path(path).stat().st_size}


def relative_path(value):
    require(isinstance(value, str) and value and "\\" not in value and
            not any(ord(c) < 32 for c in value), f"Invalid path: {value!r}")
    parts = value.split("/")
    require(not value.startswith("/") and all(p not in ("", ".", "..") for p in parts)
            and ":" not in value, f"Unsafe relative path: {value}")
    return PurePosixPath(value)


def contained(root, path):
    root = Path(root).resolve(strict=True)
    try:
        resolved = Path(path).resolve(strict=True)
        require(resolved.is_relative_to(root), f"Path escapes bundle: {path}")
    except (OSError, RuntimeError) as error:
        raise ValidationError(f"Invalid bundle path {path}: {error}") from error
    return resolved


def nonempty(root, relative):
    path = contained(root, Path(root) / relative_path(relative))
    require(path.is_file() and path.stat().st_size > 0, f"Missing/empty resource: {relative}")
    return path


def validate_bundle(app):
    app = Path(app)
    require(app.is_dir() and not app.is_symlink(), "Expected a real app directory")
    try:
        plist = plistlib.loads(nonempty(app, "Contents/Info.plist").read_bytes())
    except (ValueError, plistlib.InvalidFileException) as error:
        raise ValidationError(f"Invalid app plist: {error}") from error
    for key, expected in {
        "CFBundleShortVersionString": IDENTITY.version, "CFBundleVersion": BUILD,
        "FanqieBuildTarget": "lib/main.dart", "CFBundleIdentifier": "com.fanqie.reader.macos",
        "CFBundleExecutable": "FanqieReader", "LSMinimumSystemVersion": "12.0",
    }.items():
        require(plist.get(key) == expected, f"Wrong plist {key}: expected {expected}")
    nonempty(app, "Contents/MacOS/FanqieReader")
    nonempty(app, "Contents/Frameworks/App.framework/App")
    nonempty(app, "Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS")
    nonempty(app, ICU)
    for name in RESOURCES:
        nonempty(app, f"{ASSETS}/{name}")
    fonts = read_json(nonempty(app, f"{ASSETS}/FontManifest.json"))
    require(isinstance(fonts, list) and fonts, "Invalid FontManifest")
    mapped = {}
    for family in fonts:
        require(isinstance(family, dict) and isinstance(family.get("family"), str)
                and isinstance(family.get("fonts"), list) and family["fonts"], "Invalid font family")
        require(family["family"] not in mapped, "Duplicate font family")
        mapped[family["family"]] = []
        for font in family["fonts"]:
            require(isinstance(font, dict) and isinstance(font.get("asset"), str), "Invalid font asset")
            nonempty(app, f"{ASSETS}/{relative_path(font['asset'])}")
            mapped[family["family"]].append(font["asset"])
    for family, asset in FONTS.items():
        require(asset in mapped.get(family, []), f"Missing production font mapping: {family}")
    for name in RESOURCES:
        if name.endswith(".json"):
            value = read_json(app / ASSETS / name)
            root_type = list if name == "assets/data/charset.json" else dict
            require(isinstance(value, root_type) and value, f"Invalid/empty data resource: {name}")
    native = read_json(nonempty(app, f"{ASSETS}/NativeAssetsManifest.json"))
    require(isinstance(native, dict) and native.get("format-version") == [1, 0, 0]
            and isinstance(native.get("native-assets"), dict), "Invalid native-assets manifest")
    for target, assets in native["native-assets"].items():
        require(target == "macos_arm64" and isinstance(assets, dict), "Invalid native-assets target")
        for asset_id, loading in assets.items():
            require(isinstance(asset_id, str) and asset_id and isinstance(loading, list)
                    and loading and all(isinstance(x, str) for x in loading), "Invalid native loading")
            mode = loading[0]
            if mode in ("executable", "process"):
                require(len(loading) == 1, "Malformed lookup loading mode")
            elif mode == "absolute":
                require(len(loading) == 2, "Malformed bundled loading mode")
                parts = relative_path(loading[1]).parts
                require(len(parts) == 2 and re.fullmatch(r"[A-Za-z0-9._-]+\.framework", parts[0])
                        and parts[1] == parts[0][:-10], "Expected Mac framework/binary loading path")
                nonempty(app, f"Contents/Frameworks/{loading[1]}")
            elif mode == "system":
                require(len(loading) == 2, "Malformed system loading mode")
                path = loading[1]
                require(path.startswith(("/usr/lib/", "/System/Library/")) and
                        "\\" not in path and not any(ord(c) < 32 for c in path) and
                        all(p not in ("", ".", "..") for p in path[1:].split("/")),
                        "Unsafe system loading path")
            else:
                raise ValidationError(f"Unsupported Mac native loading mode: {mode}")
    # Walk without following directory links; validate every link, including
    # unreferenced ones, before native tools ever traverse the bundle.
    snapshot_bundle(app)


def snapshot_bundle(app):
    app = Path(app)
    require(app.is_dir() and not app.is_symlink(), "Expected real snapshot root")
    def fail_scan(error):
        raise ValidationError(f"Cannot scan bundle directory {error.filename}: {error}") from error

    snapshot = {}
    for parent, dirs, files in os.walk(app, followlinks=False, onerror=fail_scan):
        for name in sorted(dirs + files):
            path = Path(parent) / name
            key = path.relative_to(app).as_posix()
            relative_path(key)
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                target = Path(os.readlink(path)).as_posix()
                require(not os.path.isabs(target) and "\\" not in target, "Absolute/foreign bundle link")
                contained(app, path)
                snapshot[key] = {"type": "symlink", "target": target}
            elif stat.S_ISREG(mode):
                snapshot[key] = {"type": "file", "mode": stat.S_IMODE(mode), **record(path)}
            elif stat.S_ISDIR(mode):
                # os.walk suppresses DirEntry.is_dir errors into its files list.
                # Never bless a real non-link directory it will not traverse.
                require(name in dirs, f"Untraversed directory classified as a file: {key}")
                snapshot[key] = {"type": "directory", "mode": stat.S_IMODE(mode)}
            else:
                raise ValidationError(f"Special file in bundle: {key}")
    require(snapshot, "Empty bundle snapshot")
    return snapshot


def validate_snapshot(snapshot):
    require(isinstance(snapshot, dict) and snapshot, "Missing bundle snapshot")
    for path, item in snapshot.items():
        relative_path(path)
        require(isinstance(item, dict), "Invalid snapshot entry")
        kind = item.get("type")
        if kind == "file":
            validate_record({key: item.get(key) for key in ("sha256", "size")}, allow_empty=True)
        elif kind == "symlink":
            target = item.get("target")
            require(isinstance(target, str) and target and not target.startswith("/")
                    and "\\" not in target and ":" not in target
                    and not any(ord(c) < 32 for c in target), "Invalid snapshot link")
            # Resolve lexical parents without letting a link leave the app.
            parts = list(PurePosixPath(path).parent.parts)
            for part in target.split("/"):
                if part == "..":
                    require(parts, "Escaping snapshot link")
                    parts.pop()
                elif part not in ("", "."):
                    parts.append(part)
        else:
            require(kind == "directory", "Invalid snapshot entry type")
        if kind != "symlink":
            require(type(item.get("mode")) is int and 0 <= item["mode"] <= 0o777,
                    "Invalid or privileged bundle permissions")


def compare_snapshot(app, expected):
    validate_snapshot(expected)
    require(snapshot_bundle(app) == expected, "Mounted app differs from pre-image bundle snapshot")


def validate_record(item, allow_empty=False):
    require(isinstance(item, dict) and set(item) == {"sha256", "size"}, "Invalid digest/size record")
    require(isinstance(item["sha256"], str) and re.fullmatch("[0-9a-f]{64}", item["sha256"]),
            "Invalid SHA-256")
    require(type(item["size"]) is int and item["size"] >= (0 if allow_empty else 1), "Invalid size")


def validate_trigger(trigger):
    require(isinstance(trigger, dict), "Missing trigger identity")
    require(isinstance(trigger.get("source_commit"), str)
            and re.fullmatch("[0-9a-f]{40}", trigger["source_commit"]), "Invalid source SHA")
    require(isinstance(trigger.get("source_ref"), str) and (
        re.fullmatch(r"refs/heads/[A-Za-z0-9._/-]+", trigger["source_ref"])
        or trigger["source_ref"] == f"refs/tags/{IDENTITY.tag}"
    ), "Invalid source ref or tag/version mismatch")
    for key in ("run_id", "run_attempt"):
        require(isinstance(trigger.get(key), str) and re.fullmatch("[1-9][0-9]*", trigger[key]),
                f"Invalid {key}")
    require(isinstance(trigger.get("workflow_run"), str)
            and re.fullmatch(r"https://[A-Za-z0-9.-]+/[^/\s]+/[^/\s]+/actions/runs/" +
                             trigger["run_id"], trigger["workflow_run"]), "Invalid workflow run URL")


def validate_sdk(sdk):
    require(isinstance(sdk, dict) and sdk.get("frameworkVersion") == "3.47.9"
            and sdk.get("dartSdkVersion") == "3.13.7", "Wrong pinned Flutter/Dart SDK")


def validate_provenance(info, *, trigger):
    require(isinstance(info, dict), "Invalid build-info")
    validate_trigger(trigger)
    validate_trigger(info)
    for key in TRIGGER_KEYS:
        require(info.get(key) == trigger[key], f"Provenance mismatch: {key}")
    for key, value in {
        "schema": 1, "version": VERSION, "build": BUILD, "architecture": "arm64",
        "build_mode": "Release", "build_target": "lib/main.dart",
        "minimum_macos_target": "12.0", "signing": "ad-hoc", "notarized": False,
    }.items():
        require(type(info.get(key)) is type(value) and info[key] == value, f"Wrong provenance {key}")
    validate_sdk(info.get("flutter"))
    require(isinstance(info.get("xcode"), str) and info["xcode"].strip(), "Missing Xcode evidence")
    try:
        date = datetime.datetime.fromisoformat(info["built_at_utc"])
        require(date.utcoffset() == datetime.timedelta(0), "Timestamp must be UTC")
    except (KeyError, TypeError, ValueError) as error:
        raise ValidationError("Invalid build UTC timestamp") from error
    logs = info.get("test_logs")
    require(isinstance(logs, dict) and "native-xctest.log" in logs, "Missing Task1 native test evidence")
    for name, entry in logs.items():
        relative_path(name)
        require("/" not in name, "Log evidence must use basenames")
        validate_record(entry)
    snapshot = info.get("bundle_snapshot")
    validate_snapshot(snapshot)
    require(info.get("bundle_snapshot_sha256") == hashlib.sha256(canonical(snapshot)).hexdigest(),
            "Tampered bundle snapshot")
    artifacts = info.get("artifacts")
    require(isinstance(artifacts, dict) and set(artifacts) == {NAME, f"{NAME}.sha256"},
            "Wrong artifact manifest set")
    for entry in artifacts.values():
        validate_record(entry)


def create_artifacts(stage, snapshot, context):
    stage = Path(stage)
    validate_trigger(context)
    validate_sdk(context.get("flutter"))
    validate_snapshot(snapshot)
    require(set(p.name for p in stage.iterdir()) == {NAME}, "Expected only a private staged image")
    image = stage / NAME
    require(image.is_file() and not image.is_symlink() and image.stat().st_size > 0, "Invalid staged image")
    checksum = stage / f"{NAME}.sha256"
    with checksum.open("x", encoding="utf-8", newline="\n") as stream:
        stream.write(f"{digest(image)}  {NAME}\n")
    info = {key: context[key] for key in TRIGGER_KEYS}
    info.update({
        "schema": 1, "version": VERSION, "build": BUILD, "architecture": "arm64",
        "build_mode": "Release", "build_target": "lib/main.dart",
        "minimum_macos_target": "12.0", "signing": "ad-hoc", "notarized": False,
        "built_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "flutter": context["flutter"], "xcode": context.get("xcode"),
        "test_logs": context.get("test_logs"), "bundle_snapshot": snapshot,
        "bundle_snapshot_sha256": hashlib.sha256(canonical(snapshot)).hexdigest(),
        "artifacts": {p.name: record(p) for p in (image, checksum)},
    })
    validate_provenance(info, trigger=context)
    with (stage / "build-info.json").open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(info, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
    validate_artifacts(stage, context)


def validate_artifacts(directory, trigger):
    directory = Path(directory)
    require(directory.is_dir() and not directory.is_symlink(), "Invalid artifact directory")
    expected = {NAME, f"{NAME}.sha256", "build-info.json"}
    require({p.name for p in directory.iterdir()} == expected, "Missing/extra artifact files")
    for name in expected:
        path = directory / name
        require(path.is_file() and not path.is_symlink() and path.stat().st_size > 0,
                f"Invalid artifact file: {name}")
    info = read_json(directory / "build-info.json")
    validate_provenance(info, trigger=trigger)
    for name, entry in info["artifacts"].items():
        require(record(directory / name) == entry, f"Artifact digest/size mismatch: {name}")
    expected_checksum = f"{info['artifacts'][NAME]['sha256']}  {NAME}\n".encode()
    require((directory / f"{NAME}.sha256").read_bytes() == expected_checksum,
            "Invalid checksum content/path")
    return info


def output_names(mode):
    if mode == "internal":
        return (NAME, f"{NAME}.sha256", "build-info.json")
    require(mode == "release", "Unknown packaging mode")
    return (FORMAL_NAME, f"{FORMAL_NAME}.sha256")


def validate_formal_artifacts(directory):
    """Byte/checksum checks only; formal native gates are owned by the shell.

    Deliberately no ad-hoc build-info schema or CI trigger inference in this
    explicitly selected manual mode.
    """
    directory = Path(directory)
    require(directory.is_dir() and not directory.is_symlink(), "Invalid formal artifact directory")
    names = output_names("release")
    require({p.name for p in directory.iterdir()} == set(names), "Missing/extra formal artifact files")
    for name in names:
        path = directory / name
        require(path.is_file() and not path.is_symlink() and path.stat().st_size > 0,
                f"Invalid formal artifact file: {name}")
    expected = f"{digest(directory / FORMAL_NAME)}  {FORMAL_NAME}\n".encode()
    require((directory / f"{FORMAL_NAME}.sha256").read_bytes() == expected,
            "Invalid formal checksum content/path")


def check_output(output, mode="internal"):
    output = Path(output)
    require(not output.is_symlink(), "Refusing symlink output directory")
    for name in output_names(mode):
        if os.path.lexists(output / name):
            raise FileExistsError(f"Refusing existing output: {output / name}")


def publish_local_verified_artifacts(stage, output, mode="internal"):
    stage, output = Path(stage), Path(output)
    names = output_names(mode)
    if mode == "internal":
        info = read_json(stage / "build-info.json")
        validate_artifacts(stage, info)
    else:
        validate_formal_artifacts(stage)
    check_output(output, mode)
    output.mkdir(parents=True, exist_ok=True)
    # Exclusive file creation, never replace. On failure remove only files this
    # call actually created, not a concurrent publisher's or old artifacts.
    owned = []
    try:
        for name in names:
            dest = output / name
            with dest.open("xb") as target:
                owned.append(dest)
                with (stage / name).open("rb") as source:
                    shutil.copyfileobj(source, target)
        if mode == "internal":
            validate_artifacts(output, info)
        else:
            validate_formal_artifacts(output)
    except BaseException:
        for path in owned:
            path.unlink()
        raise


def release_tag(trigger):
    return f"macos-internal-v{IDENTITY.version}-{trigger['run_id']}-{trigger['run_attempt']}"


def validate_remote(local, remote, trigger, tag, release):
    validate_artifacts(local, trigger)
    validate_artifacts(remote, trigger)
    expected_tag = release_tag(trigger)
    require(isinstance(tag, dict) and tag.get("ref") == f"refs/tags/{expected_tag}"
            and tag.get("object") == {"type": "commit", "sha": trigger["source_commit"]},
            "Remote tag does not point to source commit")
    require(isinstance(release, dict) and release.get("tag_name") == expected_tag
            and release.get("prerelease") is True and release.get("draft") is False,
            "Remote release is not the expected public prerelease")
    assets = release.get("assets")
    expected = {p.name for p in Path(local).iterdir()}
    require(isinstance(assets, list) and len(assets) == len(expected) and
            all(isinstance(a, dict) for a in assets) and
            {a.get("name") for a in assets} == expected, "Wrong remote release asset set")
    for asset in assets:
        path = Path(local) / asset["name"]
        metadata = record(path)
        require(asset.get("size") == metadata["size"] and
                record(Path(remote) / asset["name"]) == metadata, "Remote asset bytes/size mismatch")
        if asset.get("digest") is not None:
            require(asset["digest"] == f"sha256:{metadata['sha256']}", "Remote asset digest mismatch")


def environment_trigger():
    required = ("GITHUB_SHA", "GITHUB_REF", "GITHUB_SERVER_URL", "GITHUB_REPOSITORY",
                "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT")
    require(all(os.environ.get(k) for k in required), "Missing workflow trigger environment")
    result = dict(zip(TRIGGER_KEYS, [
        os.environ["GITHUB_SHA"], os.environ["GITHUB_REF"],
        f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
        os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"],
    ]))
    validate_trigger(result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("bundle", "snapshot", "compare", "artifacts", "check-output", "publish-local"):
        p = sub.add_parser(name)
        p.add_argument("path", type=Path)
        if name in ("snapshot", "compare", "publish-local"):
            p.add_argument("other", type=Path)
        if name in ("check-output", "publish-local"):
            p.add_argument("--mode", choices=("internal", "release"), default="internal")
    p = sub.add_parser("create")
    p.add_argument("stage", type=Path)
    p.add_argument("--snapshot", type=Path, required=True)
    p.add_argument("--context", type=Path, required=True)
    p = sub.add_parser("context")
    p.add_argument("--sdk", type=Path, required=True)
    p.add_argument("--native-log", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p = sub.add_parser("entitlements")
    p.add_argument("path", type=Path)
    p = sub.add_parser("tag-absent")
    p.add_argument("path", type=Path)
    p = sub.add_parser("remote")
    p.add_argument("local", type=Path)
    p.add_argument("remote", type=Path)
    p.add_argument("--tag-json", type=Path, required=True)
    p.add_argument("--release-json", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "bundle":
        validate_bundle(args.path)
    elif args.command == "snapshot":
        validate_bundle(args.path)
        args.other.write_bytes(canonical(snapshot_bundle(args.path)) + b"\n")
    elif args.command == "compare":
        validate_bundle(args.path)
        compare_snapshot(args.path, read_json(args.other))
    elif args.command == "create":
        create_artifacts(args.stage, read_json(args.snapshot), read_json(args.context))
    elif args.command == "check-output":
        check_output(args.path, args.mode)
    elif args.command == "publish-local":
        publish_local_verified_artifacts(args.path, args.other, args.mode)
    elif args.command == "artifacts":
        validate_artifacts(args.path, environment_trigger())
    elif args.command == "context":
        ctx = environment_trigger()
        sdk = read_json(args.sdk)
        validate_sdk(sdk)
        require(args.native_log.is_file() and args.native_log.stat().st_size > 0, "Missing native test log")
        ctx.update(flutter=sdk, xcode=os.environ.get("MACOS_XCODE_VERSION", ""),
                   test_logs={"native-xctest.log": record(args.native_log)})
        with args.output.open("x", encoding="utf-8") as stream:
            json.dump(ctx, stream, indent=2)
            stream.write("\n")
    elif args.command == "entitlements":
        permissions = plistlib.loads(args.path.read_bytes())
        require(isinstance(permissions, dict) and set(permissions) == ENTITLEMENTS
                and all(value is True for value in permissions.values()), "Unexpected production permissions")
    elif args.command == "tag-absent":
        refs = read_json(args.path)
        require(isinstance(refs, list) and all(isinstance(r, dict) for r in refs), "Invalid remote refs")
        tag = f"refs/tags/{release_tag(environment_trigger())}"
        require(all(r.get("ref") != tag for r in refs), "Refusing an existing remote tag")
    elif args.command == "remote":
        tag = read_json(args.tag_json)
        # GitHub tag objects contain a URL as well as type/sha.
        if isinstance(tag, dict) and isinstance(tag.get("object"), dict):
            tag["object"] = {k: tag["object"].get(k) for k in ("type", "sha")}
        validate_remote(args.local, args.remote, environment_trigger(), tag, read_json(args.release_json))
    print(f"Verified {args.command}")


if __name__ == "__main__":
    try:
        main()
    except (ValidationError, OSError, ValueError, KeyError) as error:
        print(f"macOS validation failed: {error}", file=sys.stderr)
        sys.exit(1)
