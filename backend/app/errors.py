from fastapi import HTTPException, status


class ApiError(HTTPException):
    """HTTP error with a stable machine-readable code the client can localize."""

    def __init__(self, status_code: int, code: str, message: str | None = None) -> None:
        super().__init__(status_code=status_code, detail={"code": code, "message": message or code})


def not_found(code: str = "NOT_FOUND") -> ApiError:
    return ApiError(status.HTTP_404_NOT_FOUND, code)


def forbidden(code: str = "FORBIDDEN") -> ApiError:
    return ApiError(status.HTTP_403_FORBIDDEN, code)


def bad_request(code: str, message: str | None = None) -> ApiError:
    return ApiError(status.HTTP_400_BAD_REQUEST, code, message)


def conflict(code: str) -> ApiError:
    return ApiError(status.HTTP_409_CONFLICT, code)


def too_many(code: str, retry_after: int) -> ApiError:
    error = ApiError(status.HTTP_429_TOO_MANY_REQUESTS, code, f"retry after {retry_after}s")
    error.headers = {"Retry-After": str(retry_after)}
    return error


def unauthorized(code: str = "UNAUTHORIZED") -> ApiError:
    error = ApiError(status.HTTP_401_UNAUTHORIZED, code)
    error.headers = {"WWW-Authenticate": "Bearer"}
    return error
