"""Хэширование паролей: SHA-256 с индивидуальной солью."""
import hashlib
import hmac
import secrets


class PasswordHelper:
    SALT_BYTES = 16          # 16 байт -> 32 hex-символа (users.password_salt)

    @staticmethod
    def generate_salt() -> str:
        return secrets.token_hex(PasswordHelper.SALT_BYTES)

    @staticmethod
    def hash_password(password: str, salt: str) -> str:
        """SHA-256 от (соль + пароль) -> 64 hex-символа (users.password_hash)."""
        return hashlib.sha256((salt + password).encode("utf-8")).hexdigest()

    @staticmethod
    def verify_password(password: str, salt: str, stored_hash: str) -> bool:
        candidate = PasswordHelper.hash_password(password, salt)
        # сравнение за постоянное время защищает от timing-атак
        return hmac.compare_digest(candidate, stored_hash)

    @staticmethod
    def check_strength(password: str) -> list:
        problems = []
        if len(password) < 8:
            problems.append("не короче 8 символов")
        if not any(c.isdigit() for c in password):
            problems.append("хотя бы одна цифра")
        if not any(c.isalpha() for c in password):
            problems.append("хотя бы одна буква")
        return problems
