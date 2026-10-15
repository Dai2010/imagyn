#!/usr/bin/env python3
"""Generate WiX v4 components for every file in a Flutter Windows bundle."""

import hashlib
import sys
from pathlib import Path
from xml.etree import ElementTree as ET


def harvest(bundle: Path, output: Path) -> None:
    namespace = "http://wixtoolset.org/schemas/v4/wxs"
    ET.register_namespace("", namespace)

    def element(parent, name, **attributes):
        return ET.SubElement(parent, f"{{{namespace}}}{name}", attributes)

    root = ET.Element(f"{{{namespace}}}Wix")
    fragment = element(root, "Fragment")
    directories = element(fragment, "DirectoryRef", Id="INSTALLFOLDER")
    group = element(fragment, "ComponentGroup", Id="AppFiles")
    known = {Path("."): ("INSTALLFOLDER", directories)}
    files = sorted(path for path in bundle.rglob("*") if path.is_file())
    if not files:
        raise ValueError("Windows bundle is empty")
    for path in files:
        relative = path.relative_to(bundle)
        for directory in reversed(relative.parent.parents):
            if directory == Path(".") or directory in known:
                continue
            parent_id, parent = known[directory.parent]
            identifier = "D" + hashlib.sha256(directory.as_posix().encode()).hexdigest()[:32]
            known[directory] = (identifier, element(parent, "Directory", Id=identifier, Name=directory.name))
        directory = relative.parent
        if directory not in known:
            _, parent = known[directory.parent]
            identifier = "D" + hashlib.sha256(directory.as_posix().encode()).hexdigest()[:32]
            known[directory] = (identifier, element(parent, "Directory", Id=identifier, Name=directory.name))
        identifier = hashlib.sha256(relative.as_posix().encode()).hexdigest()[:32]
        component = element(group, "Component", Id="C" + identifier, Directory=known[directory][0], Guid="*")
        element(component, "File", Id="F" + identifier, Source=str(path.resolve()), KeyPath="yes")
    ET.indent(root)
    ET.ElementTree(root).write(output, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    harvest(Path(sys.argv[1]), Path(sys.argv[2]))
