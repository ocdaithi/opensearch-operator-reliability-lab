#!/usr/bin/env python3
"""Report security-relevant HCL block structure without third-party packages."""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Token:
    kind: str
    value: str
    line: int


@dataclass(frozen=True)
class Frame:
    block_type: str | None
    labels: tuple[str, ...]
    resource: str | None


IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
HEREDOC = re.compile(r"<<(-?)([A-Za-z_][A-Za-z0-9_]*)")


def tokenise(source: str, path: Path) -> list[Token]:
    tokens: list[Token] = []
    index = 0
    line = 1
    length = len(source)

    while index < length:
        character = source[index]

        if character.isspace():
            line += character == "\n"
            index += 1
            continue

        if character == "#" or source.startswith("//", index):
            newline = source.find("\n", index)
            if newline == -1:
                break
            index = newline
            continue

        if source.startswith("/*", index):
            end = source.find("*/", index + 2)
            if end == -1:
                raise ValueError(f"{path}:{line}: unterminated block comment")
            line += source.count("\n", index, end + 2)
            index = end + 2
            continue

        heredoc = HEREDOC.match(source, index)
        if heredoc:
            indented = heredoc.group(1) == "-"
            marker = heredoc.group(2)
            header_end = source.find("\n", heredoc.end())
            if header_end == -1:
                raise ValueError(f"{path}:{line}: unterminated heredoc header")
            cursor = header_end + 1
            while cursor <= length:
                next_newline = source.find("\n", cursor)
                if next_newline == -1:
                    next_newline = length
                candidate = source[cursor:next_newline]
                if (candidate.strip() if indented else candidate) == marker:
                    end = next_newline + (next_newline < length)
                    line += source.count("\n", index, end)
                    index = end
                    break
                if next_newline == length:
                    raise ValueError(f"{path}:{line}: unterminated heredoc")
                cursor = next_newline + 1
            tokens.append(Token("literal", "heredoc", line))
            continue

        if character == '"':
            token_line = line
            index += 1
            value: list[str] = []
            while index < length:
                character = source[index]
                if character == "\\":
                    if index + 1 >= length:
                        raise ValueError(f"{path}:{token_line}: unterminated escape")
                    value.append(source[index : index + 2])
                    line += source[index + 1] == "\n"
                    index += 2
                    continue
                if character == '"':
                    index += 1
                    break
                value.append(character)
                line += character == "\n"
                index += 1
            else:
                raise ValueError(f"{path}:{token_line}: unterminated quoted string")
            tokens.append(Token("string", "".join(value), token_line))
            continue

        identifier = IDENTIFIER.match(source, index)
        if identifier:
            tokens.append(Token("identifier", identifier.group(0), line))
            index = identifier.end()
            continue

        if character in "{}=":
            tokens.append(Token(character, character, line))
        else:
            tokens.append(Token("other", character, line))
        index += 1

    return tokens


def inspect(path: Path) -> dict[str, list[dict[str, object]]]:
    tokens = tokenise(path.read_text(encoding="utf-8"), path)
    result: dict[str, list[dict[str, object]]] = {
        "resources": [],
        "modules": [],
        "blocks": [],
        "attributes": [],
        "provisioners": [],
        "ignore_changes": [],
    }
    stack: list[Frame] = []
    index = 0

    while index < len(tokens):
        token = tokens[index]
        if token.kind == "identifier":
            cursor = index + 1
            labels: list[str] = []
            while cursor < len(tokens) and tokens[cursor].kind == "string":
                labels.append(tokens[cursor].value)
                cursor += 1

            if cursor < len(tokens) and tokens[cursor].kind == "{":
                resource = next(
                    (frame.resource for frame in reversed(stack) if frame.resource),
                    None,
                )
                if not stack and token.value == "resource" and len(labels) == 2:
                    resource = f"{labels[0]}.{labels[1]}"
                    result["resources"].append(
                        {"address": resource, "file": str(path), "line": token.line}
                    )
                elif not stack and token.value == "module" and len(labels) == 1:
                    result["modules"].append(
                        {"name": labels[0], "file": str(path), "line": token.line}
                    )
                if resource and stack:
                    result["blocks"].append(
                        {
                            "type": token.value,
                            "labels": labels,
                            "resource": resource,
                            "parents": [
                                frame.block_type
                                for frame in stack
                                if frame.block_type is not None
                            ],
                            "file": str(path),
                            "line": token.line,
                        }
                    )
                if token.value == "provisioner":
                    result["provisioners"].append(
                        {
                            "kind": labels[0] if labels else "<unlabelled>",
                            "resource": resource,
                            "file": str(path),
                            "line": token.line,
                        }
                    )
                stack.append(Frame(token.value, tuple(labels), resource))
                index = cursor + 1
                continue

            if (
                index + 1 < len(tokens)
                and tokens[index + 1].kind == "="
                and (resource := next(
                    (frame.resource for frame in reversed(stack) if frame.resource),
                    None,
                ))
            ):
                result["attributes"].append(
                    {
                        "name": token.value,
                        "resource": resource,
                        "parents": [
                            frame.block_type
                            for frame in stack
                            if frame.block_type is not None
                        ],
                        "file": str(path),
                        "line": token.line,
                    }
                )

            if (
                token.value == "ignore_changes"
                and index + 1 < len(tokens)
                and tokens[index + 1].kind == "="
                and any(frame.block_type == "lifecycle" for frame in stack)
            ):
                resource = next(
                    (frame.resource for frame in reversed(stack) if frame.resource),
                    None,
                )
                result["ignore_changes"].append(
                    {"resource": resource, "file": str(path), "line": token.line}
                )
        elif token.kind == "{":
            resource = next(
                (frame.resource for frame in reversed(stack) if frame.resource), None
            )
            stack.append(Frame(None, (), resource))
        elif token.kind == "}":
            if stack:
                stack.pop()
        index += 1

    return result


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: inspect-hcl-structure.py FILE.tf [...]", file=sys.stderr)
        return 2

    combined = {
        "resources": [],
        "modules": [],
        "blocks": [],
        "attributes": [],
        "provisioners": [],
        "ignore_changes": [],
    }
    try:
        for argument in sys.argv[1:]:
            report = inspect(Path(argument))
            for key in combined:
                combined[key].extend(report[key])
    except (OSError, UnicodeError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    json.dump(combined, sys.stdout, sort_keys=True, separators=(",", ":"))
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
