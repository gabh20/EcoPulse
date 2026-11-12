from datetime import datetime, timedelta, timezone
from uuid import UUID
import jwt
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pwdlib import PasswordHash
from .config import settings

password_hash = PasswordHash.recommended()
bearer = HTTPBearer(auto_error=False)


def create_token(user_id):
    return jwt.encode({"sub": str(user_id), "exp": datetime.now(timezone.utc) + timedelta(hours=settings().jwt_hours)},
                      settings().jwt_secret, algorithm="HS256")


def decode_token(token):
    try:
        return UUID(jwt.decode(token, settings().jwt_secret, algorithms=["HS256"], options={"require": ["exp", "sub"]})["sub"])
    except (jwt.InvalidTokenError, ValueError, KeyError) as error:
        raise HTTPException(401, "Sessão inválida ou expirada.") from error


def current_user(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
    if credentials is None:
        raise HTTPException(401, "Faça login para continuar.")
    return decode_token(credentials.credentials)
