from copy import deepcopy
from uuid import uuid4
import httpx
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from app.api import app
from app.auth import create_token
from app import temperature, cache


def test_grid_boundaries_and_shared_region():
    grid_id, anchor, cells = temperature.grid_for(-23.5505, -46.6333)
    assert len(cells) == 25
    assert anchor['south'] <= -23.5505 < anchor['north']
    assert grid_id == temperature.grid_for(-23.551, -46.634)[0]
    for lat, lng in [(-90, -180), (90, 180), (0, 0)]:
        for cell in temperature.grid_for(lat, lng)[2]:
            assert -90 <= cell['south'] < cell['north'] <= 90
            assert -180 <= cell['west'] < cell['east'] <= 180


def test_endpoint_requires_auth_and_valid_coordinates():
    client = TestClient(app)
    assert client.get('/environment/temperature-map?lat=0&lng=0').status_code == 401
    headers = {'Authorization': 'Bearer ' + create_token(uuid4())}
    assert client.get('/environment/temperature-map?lat=91&lng=0', headers=headers).status_code == 422


async def test_temperature_cache_hit_does_not_call_provider(monkeypatch):
    stored = {'cells': [{'temperature_celsius': 27}]}
    monkeypatch.setattr(cache, 'read', lambda key: stored)
    def unexpected(**kwargs): raise AssertionError('API externa não deveria ser consultada')
    monkeypatch.setattr(temperature.httpx, 'AsyncClient', unexpected)
    assert await temperature.temperature_grid(0, 0) == stored


@pytest.mark.parametrize('mode', ['success', 'partial', 'empty', 'invalid_unit', 'wrong_count', 'offline'])
async def test_provider_response_and_failure(monkeypatch, mode):
    monkeypatch.setattr(cache, 'read', lambda key: None)
    writes = []
    monkeypatch.setattr(cache, 'write', lambda *args, **kwargs: writes.append((args, kwargs)))
    point = {'current': {'temperature_2m': 28.5, 'time': '2026-10-12T22:00'},
             'current_units': {'temperature_2m': '°C'}}
    data = [deepcopy(point) for _ in range(25)]
    if mode == 'partial': data[0]['current']['temperature_2m'] = None
    if mode == 'empty':
        for p in data: p['current']['temperature_2m'] = None
    if mode == 'invalid_unit': data[0]['current_units']['temperature_2m'] = '°F'
    if mode == 'wrong_count': data.pop()
    class Client:
        async def __aenter__(self): return self
        async def __aexit__(self, *args): pass
        async def get(self, url, params):
            assert len(params['latitude'].split(',')) == 25
            assert params['temperature_unit'] == 'celsius'
            if mode == 'offline': raise httpx.ConnectError('offline')
            return httpx.Response(200, json=data, request=httpx.Request('GET', url))
    monkeypatch.setattr(temperature.httpx, 'AsyncClient', lambda **kwargs: Client())
    if mode in ('success', 'partial'):
        result = await temperature.temperature_grid(-23.5505, -46.6333)
        assert len(result['cells']) == (24 if mode == 'partial' else 25)
        assert result['missing_cells'] == (1 if mode == 'partial' else 0)
        assert result['cells'][0]['temperature_celsius'] == 28.5
        assert result['cells'][0]['weather_time'].endswith('+00:00')
        assert writes[0][1]['ttl'] == 600
    else:
        with pytest.raises(HTTPException) as error:
            await temperature.temperature_grid(0, 0)
        assert error.value.status_code == 503
        assert not writes
