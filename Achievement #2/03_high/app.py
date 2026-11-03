import json
import logging
import os
from contextlib import asynccontextmanager

import psycopg
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ConfigDict, Field


logger = logging.getLogger("uvicorn.error")

SCHEMA = """
CREATE TABLE IF NOT EXISTS received_numbers (
    number BIGINT PRIMARY KEY CHECK (number >= 0),
    processed BOOLEAN NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
)
"""


def connect(database_url):
    connection = psycopg.connect(
        database_url,
        connect_timeout=5,
        options="-c statement_timeout=10000 -c lock_timeout=5000",
    )
    connection.isolation_level = psycopg.IsolationLevel.READ_COMMITTED
    return connection


def process_number(database_url, number):
    with connect(database_url) as connection:
        connection.execute("LOCK TABLE received_numbers IN EXCLUSIVE MODE")
        duplicate = connection.execute(
            "SELECT 1 FROM received_numbers WHERE number = %s", (number,)
        ).fetchone()
        if duplicate:
            return "ALREADY_RECEIVED"

        successor = connection.execute(
            "SELECT 1 FROM received_numbers WHERE number = %s AND processed",
            (number + 1,),
        ).fetchone()
        connection.execute(
            "INSERT INTO received_numbers (number, processed) VALUES (%s, %s)",
            (number, successor is None),
        )
        if successor:
            return "SUCCESSOR_ALREADY_PROCESSED"

    return None


def create_app(database_url=None, max_number=None):
    if database_url is None:
        database_url = os.environ["DATABASE_URL"]
    if max_number is None:
        max_number = int(os.getenv("MAX_NUMBER", "1000"))
    if type(max_number) is not int or not 0 <= max_number < 2**63 - 1:
        raise ValueError("MAX_NUMBER must be an integer between 0 and 9223372036854775806")

    class NumberRequest(BaseModel):
        model_config = ConfigDict(extra="forbid")
        number: int = Field(strict=True, ge=0, le=max_number)

    @asynccontextmanager
    async def lifespan(application):
        with connect(database_url) as connection:
            connection.execute("SELECT pg_advisory_xact_lock(20260002)")
            connection.execute(SCHEMA)
        yield

    application = FastAPI(
        title="Achievement #2",
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )

    @application.exception_handler(RequestValidationError)
    async def invalid_request(request: Request, exception: RequestValidationError):
        logger.warning(json.dumps({"event": "INVALID_REQUEST"}))
        return JSONResponse(
            status_code=422,
            content={"error": {"code": "INVALID_REQUEST"}},
        )

    @application.get("/health")
    def health():
        try:
            with connect(database_url) as connection:
                connection.execute("SELECT 1")
        except psycopg.Error:
            return JSONResponse(status_code=503, content={"status": "unavailable"})
        return {"status": "ok"}

    @application.post("/increment")
    def increment(payload: NumberRequest):
        try:
            error = process_number(database_url, payload.number)
        except psycopg.Error:
            logger.error(
                json.dumps({"event": "DATABASE_UNAVAILABLE", "number": payload.number})
            )
            return JSONResponse(
                status_code=503,
                content={"error": {"code": "DATABASE_UNAVAILABLE"}},
            )

        if error:
            logger.warning(json.dumps({"event": error, "number": payload.number}))
            return JSONResponse(
                status_code=409,
                content={"error": {"code": error, "number": payload.number}},
            )
        return {"result": payload.number + 1}

    return application
