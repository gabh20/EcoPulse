from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock
from uuid import uuid4
import pytest
from fastapi.testclient import TestClient
from fastapi import HTTPException
from app.api import app
from app import cache, environment, reports, worker, broker
from app.auth import create_token
from app.contracts import ReportInput
from test_rules import payload


def test_cache_failure_is_nonfatal(monkeypatch):
    def fail(): raise ConnectionError('offline')
    monkeypatch.setattr(cache, 'client', fail)
    assert cache.read('x') is None
    cache.write('x', [])


def test_nearby_filters_exact_position_and_expiry(monkeypatch):
    monkeypatch.setattr(cache, 'reports_version', lambda: '0')
    now = datetime.now(timezone.utc)
    rows = [dict(id='near',latitude=0,longitude=0.01,expires_at=(now+timedelta(hours=1)).isoformat()),
            dict(id='far',latitude=0,longitude=0.1,expires_at=(now+timedelta(hours=1)).isoformat()),
            dict(id='expired',latitude=0,longitude=0,expires_at=(now-timedelta(seconds=1)).isoformat())]
    monkeypatch.setattr(cache,'read', lambda key: rows)
    assert [r['id'] for r in reports.nearby(0,0,3000)] == ['near']


async def test_environment_failure_returns_unavailable(monkeypatch):
    monkeypatch.setattr(cache,'read', lambda key: None)
    class OfflineClient:
        async def __aenter__(self): return self
        async def __aexit__(self,*args): pass
        async def get(self,*args,**kwargs): raise environment.httpx.ConnectError('offline')
    monkeypatch.setattr(environment.httpx,'AsyncClient',lambda **kwargs: OfflineClient())
    with pytest.raises(HTTPException) as error:
        await environment.conditions(0,0)
    assert error.value.status_code == 503


def test_http_requires_login_and_valid_coordinates():
    client = TestClient(app)
    assert client.get('/reports/nearby?lat=0&lng=0').status_code == 401
    headers = {'Authorization': 'Bearer ' + create_token(uuid4())}
    assert client.get('/reports/nearby?lat=91&lng=0',headers=headers).status_code == 422
    assert client.post('/reports',json=payload(type='UNKNOWN'),headers=headers).status_code == 422


async def test_worker_duplicate_does_not_emit_new_event(monkeypatch):
    user_id = uuid4()
    data = ReportInput.model_validate(payload()).model_dump(mode='json')
    event = {'user_id':str(user_id),'report':data}
    statements = []
    class Result:
        def __init__(self,row): self.row=row
        def fetchone(self): return self.row
    class Connection:
        def execute(self,sql,args):
            statements.append(sql)
            if sql.startswith('SELECT'): return Result({'user_id':user_id,'payload':data})
            return Result(None)
    @contextmanager
    def fake_database(): yield Connection()
    monkeypatch.setattr(worker,'database',fake_database)
    await worker.process(event)
    assert len(statements) == 2
    assert not any('INSERT INTO outbox' in sql for sql in statements)


async def test_publish_is_persistent_and_mandatory():
    from aio_pika import DeliveryMode
    channel = AsyncMock()
    await broker.send(channel,'reports.0',{'id':'stable'},attempt=1)
    call = channel.default_exchange.publish.call_args
    message = call.args[0]
    assert message.delivery_mode == DeliveryMode.PERSISTENT
    assert message.headers['attempt'] == 1
    assert call.kwargs['mandatory'] is True


async def test_topology_includes_delayed_retries_and_dlq():
    channel = AsyncMock()
    await broker.topology(channel)
    declared = {call.args[0]: call.kwargs for call in channel.declare_queue.call_args_list}
    for queue in broker.QUEUES:
        assert declared[queue]['durable']
        assert queue+'.dead' in declared
        assert declared[queue+'.retry.3']['arguments']['x-message-ttl'] == 30000
        assert declared[queue+'.retry.1']['arguments']['x-dead-letter-routing-key'] == queue
