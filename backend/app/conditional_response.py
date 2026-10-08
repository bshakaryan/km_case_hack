"""Conditional GET over an already authorized, freshly serialized response.

There is no server response cache: callers must authenticate, authorize, filter
and compute the complete current representation before invoking this helper.
"""

import hashlib
import json

from fastapi.responses import JSONResponse, Response


MAX_IF_NONE_MATCH_LENGTH = 4096


def _matches_if_none_match(value, etag):
    """RFC 9110 weak read comparison; invalid fields fall back to a full 200.

    Parse the whole bounded field before returning a match. Commas inside an
    opaque tag are not list separators; a wildcard cannot appear in a tag list.
    A reasonable number of empty list members is accepted (RFC 9110 5.6.1.2).
    https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.2
    """
    value = value.strip(" \t")
    if value == "*":
        return True
    matched = False
    position = 0
    empty_members = 0
    while position < len(value):
        while position < len(value) and value[position] in " \t":
            position += 1
        if position == len(value):
            break
        if value[position] == ",":
            empty_members += 1
            if empty_members > 32:
                return False
            position += 1
            continue
        if value.startswith("W/", position):
            position += 2
        if position >= len(value) or value[position] != '"':
            return False
        end = value.find('"', position + 1)
        if end == -1:
            return False
        if any(not (ord(character) == 0x21 or 0x23 <= ord(character) <= 0x7E
                    or 0x80 <= ord(character) <= 0xFF)
               for character in value[position + 1:end]):
            return False
        matched = matched or value[position:end + 1] == etag
        position = end + 1
        while position < len(value) and value[position] in " \t":
            position += 1
        if position < len(value):
            if value[position] != ",":
                return False
            position += 1
    return matched


def conditional_json_response(content, *, scope, if_none_match):
    """Return the exact fresh JSON bytes, or an empty 304 with their validator.

    Authority/query scope stays inside the digest; no token or session hash is
    exposed. Repeated If-None-Match fields form one list, bounded before joining.
    The same tag guarantees identical bytes in this particular authority/query
    scope, including computed fields which can change without an order version.
    """
    response = JSONResponse(content)
    scope_bytes = json.dumps(scope, sort_keys=True, ensure_ascii=False,
                            separators=(",", ":")).encode("utf-8")
    digest = hashlib.sha256(b"orders-v1\x00" + scope_bytes + b"\x00" + response.body).hexdigest()
    etag = f'"orders-v1-{digest}"'
    headers = {"ETag": etag, "Cache-Control": "private, no-cache", "Vary": "Authorization"}
    field_length = sum(len(value) for value in if_none_match) + max(0, len(if_none_match) - 1)
    if 0 < field_length <= MAX_IF_NONE_MATCH_LENGTH and _matches_if_none_match(",".join(if_none_match), etag):
        return Response(status_code=304, headers=headers)
    response.headers.update(headers)
    return response
