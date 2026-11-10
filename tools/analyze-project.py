#!/usr/bin/env python3
import configparser
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(sys.argv[1]).resolve()
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"
SKIP = {".git", "build", ".gradle", "node_modules", ".universal-builder"}


def show(label, value):
    print(f"{label}: {value if value else 'Não declarado'}")


def project_files(name):
    for path in root.rglob(name):
        if any(part in SKIP for part in path.relative_to(root).parts):
            continue
        if path.is_file():
            yield path


def gradle_value(content, names):
    for name in names:
        pattern = rf"\b{re.escape(name)}\s*(?:=|\s)\s*[\"']?([A-Za-z0-9_.+-]+)"
        match = re.search(pattern, content)
        if match:
            return match.group(1)
    return None


def python_metadata():
    """Read common, static Python build metadata without third-party modules."""
    requires_python = None
    backend = None
    build_requires = []

    pyproject = root / "pyproject.toml"
    if pyproject.is_file():
        content = pyproject.read_text(encoding="utf-8", errors="replace")
        try:
            import tomllib
            data = tomllib.loads(content)
            project = data.get("project", {})
            tool = data.get("tool", {})
            poetry = tool.get("poetry", {}) if isinstance(tool, dict) else {}
            requires_python = project.get("requires-python") or (
                poetry.get("dependencies", {}).get("python")
                if isinstance(poetry.get("dependencies", {}), dict) else None
            )
            build_system = data.get("build-system", {})
            backend = build_system.get("build-backend")
            build_requires = build_system.get("requires", []) or []
        except (ImportError, ValueError):
            # Python 3.10 has no tomllib. Read only the standard static keys.
            project_section = re.search(
                r"(?ms)^\[project\]\s*(.*?)(?=^\[|\Z)", content
            )
            if project_section:
                match = re.search(
                    r'''(?m)^requires-python\s*=\s*["']([^"']+)["']''',
                    project_section.group(1)
                )
                if match:
                    requires_python = match.group(1)
            build_section = re.search(
                r"(?ms)^\[build-system\]\s*(.*?)(?=^\[|\Z)", content
            )
            if build_section:
                section = build_section.group(1)
                match = re.search(
                    r'''(?m)^build-backend\s*=\s*["']([^"']+)["']''',
                    section
                )
                if match:
                    backend = match.group(1)
                match = re.search(r"(?m)^requires\s*=\s*\[([^]]*)\]", section)
                if match:
                    build_requires = re.findall(r'''["']([^"']+)["']''', match.group(1))

    setup_cfg = root / "setup.cfg"
    if setup_cfg.is_file():
        parser = configparser.ConfigParser()
        try:
            parser.read(setup_cfg, encoding="utf-8")
            requires_python = requires_python or parser.get(
                "options", "python_requires", fallback=None
            )
        except configparser.Error:
            pass

    setup_py = root / "setup.py"
    if setup_py.is_file() and not requires_python:
        content = setup_py.read_text(encoding="utf-8", errors="replace")
        match = re.search(r'''python_requires\s*=\s*["']([^"']+)["']''', content)
        if match:
            requires_python = match.group(1)

    version_file = root / ".python-version"
    python_version = (
        version_file.read_text(encoding="utf-8", errors="replace").strip()
        if version_file.is_file() else None
    )
    return requires_python, backend, build_requires, python_version


print("\n===== REQUISITOS IDENTIFICADOS =====")

manifests = list(project_files("AndroidManifest.xml"))
if manifests:
    for manifest in manifests:
        try:
            element = ET.parse(manifest).getroot()
            sdk = element.find("uses-sdk")
            print(f"\n[ANDROID] {manifest.relative_to(root)}")
            show("Pacote", element.get("package"))
            show("Min SDK", sdk.get(ANDROID_NS + "minSdkVersion") if sdk is not None else None)
            show("Target SDK", sdk.get(ANDROID_NS + "targetSdkVersion") if sdk is not None else None)
        except ET.ParseError as exc:
            print(f"[ERRO] Manifest inválido ({manifest}): {exc}")

gradle_files = list(project_files("build.gradle")) + list(project_files("build.gradle.kts"))
seen = set()

for gradle in gradle_files:
    if gradle in seen:
        continue
    seen.add(gradle)
    content = gradle.read_text(errors="replace")
    values = {
        "compileSdk": gradle_value(content, ["compileSdkVersion", "compileSdk"]),
        "buildToolsVersion": gradle_value(content, ["buildToolsVersion"]),
        "ndkVersion": gradle_value(content, ["ndkVersion"]),
        "minSdk": gradle_value(content, ["minSdkVersion", "minSdk"]),
        "targetSdk": gradle_value(content, ["targetSdkVersion", "targetSdk"]),
    }
    if any(values.values()):
        print(f"\n[GRADLE] {gradle.relative_to(root)}")
        for key, value in values.items():
            if value:
                show(key, value)

    agp = re.search(
        r"com\.android\.tools\.build:gradle:([0-9][A-Za-z0-9.+_-]*)",
        content
    )
    if agp:
        show("Android Gradle Plugin", agp.group(1))

for application in project_files("Application.mk"):
    content = application.read_text(errors="replace")
    print(f"\n[ANDROID NDK] {application.relative_to(root)}")
    for key in ("APP_PLATFORM", "NDK_TOOLCHAIN_VERSION", "APP_ABI", "APP_STL"):
        match = re.search(
            rf"^\s*{re.escape(key)}\s*:?=\s*(.*?)\s*$",
            content,
            re.MULTILINE
        )
        show(key, match.group(1) if match else None)

local = root / "local.properties"
if local.is_file():
    print("\n[ANDROID LOCAL]")
    for line in local.read_text(errors="replace").splitlines():
        if re.match(r"^\s*(sdk|ndk)\.dir\s*=", line):
            print(line.strip())

wrappers = list(project_files("gradle-wrapper.properties"))
for wrapper in wrappers:
    content = wrapper.read_text(errors="replace")
    match = re.search(r"gradle-([0-9][0-9.]*)-(?:all|bin)\.zip", content)
    print(f"\n[GRADLE WRAPPER] {wrapper.relative_to(root)}")
    show("Versão", match.group(1) if match else None)

python_markers = any(
    (root / name).is_file()
    for name in ("pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile")
)
if python_markers:
    requires_python, backend, build_requires, python_version = python_metadata()
    print("\n[PYTHON]")
    show("Versão exigida (requires-python)", requires_python)
    show("Versão fixada (.python-version)", python_version)
    show("Backend de build", backend)
    show("Dependências de build", ", ".join(build_requires) if build_requires else None)

if list(project_files("Android.mk")):
    print("\n[BUILD SYSTEM]\nAndroid NDK: ndk-build (Android.mk)")
elif gradle_files:
    print("\n[BUILD SYSTEM]\nGradle")
elif (root / "CMakeLists.txt").is_file():
    print("\n[BUILD SYSTEM]\nCMake")
elif (root / "Makefile").is_file():
    print("\n[BUILD SYSTEM]\nMakefile")
elif python_markers:
    print("\n[BUILD SYSTEM]\nPython (pyproject/setup)")
elif (root / "pom.xml").is_file():
    print("\n[BUILD SYSTEM]\nMaven")

print("\n===== FIM DA ANÁLISE ESTRUTURADA =====")
