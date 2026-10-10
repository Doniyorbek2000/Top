from fastapi import HTTPException, status


class ApiError(HTTPException):
    """HTTP error with a stable machine-readable code the client can localize."""

    def __init__(self, status_code: int, code: str, message: str | None = None, headers: dict[str, str] | None = None) -> None:
        super().__init__(status_code=status_code, detail={"code": code, "message": message or code}, headers=headers)


def bad_request(code: str, message: str | None = None) -> ApiError:
    return ApiError(status.HTTP_400_BAD_REQUEST, code, message)


def unauthorized(code: str = "UNAUTHORIZED") -> ApiError:
    return ApiError(status.HTTP_401_UNAUTHORIZED, code, headers={"WWW-Authenticate": "Bearer"})


def forbidden(code: str = "FORBIDDEN") -> ApiError:
    return ApiError(status.HTTP_403_FORBIDDEN, code)


def not_found(code: str = "NOT_FOUND") -> ApiError:
    return ApiError(status.HTTP_404_NOT_FOUND, code)


def conflict(code: str, message: str | None = None) -> ApiError:
    return ApiError(status.HTTP_409_CONFLICT, code, message)


def unavailable(code: str, message: str | None = None) -> ApiError:
    return ApiError(status.HTTP_503_SERVICE_UNAVAILABLE, code, message)


def too_many(retry_after: int) -> ApiError:
    return ApiError(status.HTTP_429_TOO_MANY_REQUESTS, "RATE_LIMITED", headers={"Retry-After": str(retry_after)})
