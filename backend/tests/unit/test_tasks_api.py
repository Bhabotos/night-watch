import pytest
from fastapi.testclient import TestClient

URL = "/api/v1/tasks"


def make(client: TestClient, **body) -> dict:
    body.setdefault("title", "Write docs")
    response = client.post(URL, json=body)
    assert response.status_code == 201, response.text
    return response.json()


def test_create_returns_201_with_defaults(client):
    task = make(client, title="  Write docs  ", description="details")
    assert task["title"] == "Write docs"  # whitespace stripped
    assert task["status"] == "todo"
    assert task["description"] == "details"
    assert task["id"] >= 1
    assert task["created_at"]
    assert task["updated_at"]


def test_get_returns_task_and_404_for_missing(client):
    task = make(client)
    assert client.get(f"{URL}/{task['id']}").json() == task
    missing = client.get(f"{URL}/99999")
    assert missing.status_code == 404
    assert missing.json()["error"]["code"] == "task_not_found"


def test_list_filters_and_paginates(client):
    for i in range(5):
        make(client, title=f"t{i}", status="done" if i % 2 else "todo")
    everything = client.get(URL).json()
    assert everything["total"] == 5
    assert [t["title"] for t in everything["items"]] == ["t4", "t3", "t2", "t1", "t0"]
    done = client.get(URL, params={"status": "done"}).json()
    assert done["total"] == 2
    assert {t["status"] for t in done["items"]} == {"done"}
    page = client.get(URL, params={"limit": 2, "offset": 2}).json()
    assert [t["title"] for t in page["items"]] == ["t2", "t1"]
    assert page["total"] == 5


def test_list_limit_is_capped_by_max_page_size(client):
    assert client.get(URL, params={"limit": 1000}).json()["limit"] == 50


def test_put_replaces_all_fields(client):
    task = make(client, description="old", status="in_progress")
    response = client.put(f"{URL}/{task['id']}", json={"title": "New"})
    assert response.status_code == 200
    body = response.json()
    assert (body["title"], body["description"], body["status"]) == ("New", None, "todo")


def test_patch_changes_only_supplied_fields(client):
    task = make(client, description="keep me")
    response = client.patch(f"{URL}/{task['id']}", json={"status": "done"})
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "done"
    assert body["description"] == "keep me"
    assert body["title"] == task["title"]


def test_patch_can_clear_description(client):
    task = make(client, description="x")
    body = client.patch(f"{URL}/{task['id']}", json={"description": None}).json()
    assert body["description"] is None


def test_delete_then_404(client):
    task = make(client)
    assert client.delete(f"{URL}/{task['id']}").status_code == 204
    assert client.get(f"{URL}/{task['id']}").status_code == 404
    assert client.delete(f"{URL}/{task['id']}").status_code == 404


def test_update_and_delete_missing_return_404(client):
    assert client.put(f"{URL}/42", json={"title": "x"}).status_code == 404
    assert client.patch(f"{URL}/42", json={"title": "x"}).status_code == 404


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"title": ""},
        {"title": "   "},
        {"title": "x" * 201},
        {"title": "ok", "status": "bogus"},
        {"title": "ok", "description": "d" * 5001},
        {"title": "ok", "unexpected": 1},
        {"title": None},
    ],
)
def test_create_rejects_invalid_bodies(client, body):
    response = client.post(URL, json=body)
    assert response.status_code == 422
    error = response.json()["error"]
    assert error["code"] == "validation_error"
    assert error["details"]


@pytest.mark.parametrize("body", [{}, {"title": None}, {"status": None}, {"status": "nope"}])
def test_patch_rejects_invalid_bodies(client, body):
    task = make(client)
    assert client.patch(f"{URL}/{task['id']}", json=body).status_code == 422


def test_invalid_query_and_path_params(client):
    assert client.get(URL, params={"limit": 0}).status_code == 422
    assert client.get(URL, params={"offset": -1}).status_code == 422
    assert client.get(URL, params={"status": "bogus"}).status_code == 422
    assert client.get(f"{URL}/abc").status_code == 422


def test_validation_error_does_not_echo_submitted_input(client):
    secret = "s3cr3t-value-that-must-not-come-back"
    response = client.post(URL, json={"title": "ok", "status": secret})
    assert response.status_code == 422
    assert secret not in response.text


def test_malformed_json_is_422_with_error_shape(client):
    response = client.post(URL, content="{not json", headers={"content-type": "application/json"})
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"
