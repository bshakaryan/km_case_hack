import hashlib
import hmac
import secrets


def hash_pin(pin: str) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", pin.encode(), bytes.fromhex(salt), 260_000)
    return f"pbkdf2_sha256$260000${salt}${digest.hex()}"


def check_pin(pin: str, stored: str) -> bool:
    try:
        _, iterations, salt, expected = stored.split("$")
        actual = hashlib.pbkdf2_hmac("sha256", pin.encode(), bytes.fromhex(salt), int(iterations)).hex()
        return hmac.compare_digest(actual, expected)
    except (ValueError, TypeError):
        return False


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()
