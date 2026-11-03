import json
import logging
import os
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier

import psycopg
import pytest
from fastapi.testclient import TestClient

import app as app_module
from app import create_app


@pytest.fixture
def database_url():
    return os.environ["TEST_DATABASE_URL"]


@pytest.fixture
def client(database_url):
    with TestClient(create_app(database_url, 100)) as test_client:
        with psycopg.connect(database_url) as connection:
            connection.execute("TRUNCATE received_numbers")
        yield test_client


@pytest.mark.parametrize("number", [0, 42, 100])
def test_increment_and_boundaries(client, number):
    response = client.post("/increment", json={"number": number})
    assert response.status_code == 200
    assert response.json() == {"result": number + 1}


def test_duplicate_is_rejected_and_logged(client, caplog):
    assert client.post("/increment", json={"number": 10}).status_code == 200
    with caplog.at_level(logging.WARNING, logger="uvicorn.error"):
        response = client.post("/increment", json={"number": 10})
    assert response.status_code == 409
    assert response.json() == {"error": {"code": "ALREADY_RECEIVED", "number": 10}}
    assert {"event": "ALREADY_RECEIVED", "number": 10} in [
        json.loads(record.message) for record in caplog.records
    ]


def test_predecessor_is_rejected_and_logged(client, caplog):
    assert client.post("/increment", json={"number": 10}).status_code == 200
    with caplog.at_level(logging.WARNING, logger="uvicorn.error"):
        response = client.post("/increment", json={"number": 9})
    assert response.status_code == 409
    assert response.json() == {
        "error": {"code": "SUCCESSOR_ALREADY_PROCESSED", "number": 9}
    }
    assert {"event": "SUCCESSOR_ALREADY_PROCESSED", "number": 9} in [
        json.loads(record.message) for record in caplog.records
    ]


def test_rejected_number_counts_as_received_but_not_processed(client):
    assert client.post("/increment", json={"number": 10}).status_code == 200
    assert client.post("/increment", json={"number": 9}).status_code == 409
    response = client.post("/increment", json={"number": 9})
    assert response.json()["error"]["code"] == "ALREADY_RECEIVED"
    response = client.post("/increment", json={"number": 8})
    assert response.status_code == 200
    assert response.json() == {"result": 9}


def test_result_is_not_registered_as_input(client):
    assert client.post("/increment", json={"number": 10}).json() == {"result": 11}
    assert client.post("/increment", json={"number": 11}).json() == {"result": 12}


@pytest.mark.parametrize(
    "payload",
    [
        {"number": -1},
        {"number": 101},
        {"number": 2**63},
        {"number": 1.5},
        {"number": 1.0},
        {"number": True},
        {"number": "1"},
        {"number": None},
        {"number": 1, "extra": 2},
        {},
        [],
        1,
    ],
)
def test_invalid_payload(client, payload, database_url):
    response = client.post("/increment", json=payload)
    assert response.status_code == 422
    assert response.json() == {"error": {"code": "INVALID_REQUEST"}}
    with psycopg.connect(database_url) as connection:
        assert connection.execute("SELECT count(*) FROM received_numbers").fetchone()[0] == 0


def test_malformed_json(client):
    response = client.post(
        "/increment", content='{"number":', headers={"Content-Type": "application/json"}
    )
    assert response.status_code == 422


def test_get_cannot_change_numbers(client):
    assert client.get("/increment").status_code == 405


def test_concurrent_duplicates(client, database_url):
    barrier = Barrier(8)

    def send():
        barrier.wait(timeout=10)
        return client.post("/increment", json={"number": 20})

    with ThreadPoolExecutor(max_workers=8) as executor:
        responses = list(executor.map(lambda _: send(), range(8)))

    assert sorted(response.status_code for response in responses) == [200] + [409] * 7
    assert all(
        response.json()["error"]["code"] == "ALREADY_RECEIVED"
        for response in responses
        if response.status_code == 409
    )
    with psycopg.connect(database_url) as connection:
        assert connection.execute(
            "SELECT number, processed FROM received_numbers"
        ).fetchall() == [(20, True)]


def test_concurrent_adjacent_numbers(client, database_url):
    barrier = Barrier(2)

    def send(number):
        barrier.wait(timeout=10)
        return client.post("/increment", json={"number": number})

    with ThreadPoolExecutor(max_workers=2) as executor:
        lower, upper = list(executor.map(send, [30, 31]))

    assert upper.status_code == 200
    assert lower.status_code in (200, 409)
    if lower.status_code == 409:
        assert lower.json()["error"]["code"] == "SUCCESSOR_ALREADY_PROCESSED"
    with psycopg.connect(database_url) as connection:
        assert connection.execute(
            "SELECT number, processed FROM received_numbers ORDER BY number"
        ).fetchall() == [(30, lower.status_code == 200), (31, True)]


def test_history_survives_application_restart(client, database_url):
    assert client.post("/increment", json={"number": 50}).status_code == 200
    with TestClient(create_app(database_url, 100)) as another_client:
        response = another_client.post("/increment", json={"number": 50})
        assert response.status_code == 409
        assert response.json()["error"]["code"] == "ALREADY_RECEIVED"


def test_zero_maximum(database_url):
    with TestClient(create_app(database_url, 0)) as test_client:
        with psycopg.connect(database_url) as connection:
            connection.execute("TRUNCATE received_numbers")
        assert test_client.post("/increment", json={"number": 0}).json() == {"result": 1}
        assert test_client.post("/increment", json={"number": 1}).status_code == 422


def test_database_failure(client, monkeypatch, caplog):
    def unavailable(*args, **kwargs):
        raise psycopg.OperationalError("unavailable")

    monkeypatch.setattr(app_module, "connect", unavailable)
    with caplog.at_level(logging.ERROR, logger="uvicorn.error"):
        response = client.post("/increment", json={"number": 1})
    assert response.status_code == 503
    assert response.json() == {"error": {"code": "DATABASE_UNAVAILABLE"}}
    assert "DATABASE_UNAVAILABLE" in caplog.text


@pytest.mark.parametrize("maximum", [-1, 2**63 - 1, True, 1.5])
def test_invalid_maximum(database_url, maximum):
    with pytest.raises(ValueError):
        create_app(database_url, maximum)
