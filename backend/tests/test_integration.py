import os
import json
import time
from uuid import uuid4
from datetime import datetime, timezone
import httpx
import pytest
from websockets.sync.client import connect

pytestmark = [pytest.mark.integration, pytest.mark.skipif(os.getenv('RUN_INTEGRATION') != '1',reason='Docker Compose necessário')]
BASE = os.getenv('API_URL','http://localhost:8000')


def test_real_pipeline_idempotence_and_geo():
    email = f'{uuid4()}@example.com'
    with httpx.Client(base_url=BASE,timeout=20) as client:
        response = client.post('/auth/register',json={'name':'Teste integração','email':email,'password':'senha12345'})
        assert response.status_code == 201, response.text
        login = client.post('/auth/login',json={'email':email,'password':'senha12345'})
        assert login.status_code == 200
        client.headers['Authorization'] = 'Bearer '+login.json()['access_token']
        report = {'id':str(uuid4()),'type':'FLOOD','description':'DADO DE TESTE automatizado',
            'latitude':-23.5505,'longitude':-46.6333,'accuracy_meters':10,'observed_at':datetime.now(timezone.utc).isoformat()}
        assert client.post('/reports',json=report).status_code in (200,202)
        assert client.post('/reports',json=report).status_code in (200,202)
        for _ in range(45):
            status = client.get('/reports/'+report['id']).json()
            if status['state'] == 'PROCESSED': break
            time.sleep(1)
        assert status['state'] == 'PROCESSED'
        nearby = client.get('/reports/nearby',params={'lat':-23.5505,'lng':-46.6333,'radius_meters':3000})
        assert sum(r['id']==report['id'] for r in nearby.json()) == 1
        far = client.get('/reports/nearby',params={'lat':0,'lng':0,'radius_meters':3000})
        assert not any(r['id']==report['id'] for r in far.json())
        assert client.post('/reports',json={**report,'description':'conteúdo alterado'}).status_code == 409


def test_old_offline_report_expires_without_becoming_active():
    with httpx.Client(base_url=BASE,timeout=20) as client:
        email = f'{uuid4()}@example.com'
        client.post('/auth/register',json={'name':'Teste offline','email':email,'password':'senha12345'})
        token = client.post('/auth/login',json={'email':email,'password':'senha12345'}).json()['access_token']
        client.headers['Authorization'] = 'Bearer '+token
        report = {'id':str(uuid4()),'type':'HEAT','description':'DADO DE TESTE antigo','latitude':0,'longitude':0,
            'accuracy_meters':1,'observed_at':'2020-01-01T12:00:00Z'}
        assert client.post('/reports',json=report).status_code == 202
        for _ in range(45):
            result = client.get('/reports/'+report['id']).json()
            if result['state'] == 'EXPIRED': break
            time.sleep(1)
        assert result['state'] == 'EXPIRED'
        assert client.post('/reports/' + report['id'] + '/resolve').status_code == 409


def test_resolve_authorization_cache_and_duplicate_delivery():
    with httpx.Client(base_url=BASE, timeout=20) as author, httpx.Client(base_url=BASE, timeout=20) as other:
        for client in (author, other):
            email = f'{uuid4()}@example.com'
            assert client.post('/auth/register', json={'name': 'Teste resolução', 'email': email, 'password': 'senha12345'}).status_code == 201
            token = client.post('/auth/login', json={'email': email, 'password': 'senha12345'}).json()['access_token']
            client.headers['Authorization'] = 'Bearer ' + token
        report = {'id': str(uuid4()), 'type': 'HEAT', 'description': 'DADO DE TESTE resolução',
                  'latitude': -23.5505, 'longitude': -46.6333, 'accuracy_meters': 10,
                  'observed_at': datetime.now(timezone.utc).isoformat()}
        route = '/reports/' + report['id']
        assert author.post('/reports', json=report).status_code == 202
        for _ in range(45):
            if author.get(route).json()['state'] == 'PROCESSED':
                break
            time.sleep(1)
        assert author.get(route).json()['state'] == 'PROCESSED'
        params = {'lat': report['latitude'], 'lng': report['longitude'], 'radius_meters': 3000}
        assert any(row['id'] == report['id'] for row in other.get('/reports/nearby', params=params).json())
        assert other.post(route + '/resolve').status_code == 403
        assert httpx.post(BASE + route + '/resolve').status_code == 401
        assert author.post(route + '/resolve').json()['state'] == 'RESOLVED'
        assert author.post(route + '/resolve').json()['state'] == 'RESOLVED'
        assert author.get(route).json()['report']['status'] == 'RESOLVED'
        assert not any(row['id'] == report['id'] for row in other.get('/reports/nearby', params=params).json())
        assert author.post('/reports', json=report).json()['state'] == 'RESOLVED'
        assert author.get(route).json()['state'] == 'RESOLVED'
        assert author.post('/reports/' + str(uuid4()) + '/resolve').status_code == 404


def test_websocket_removes_resolved_report():
    with httpx.Client(base_url=BASE, timeout=20) as client:
        email = f'{uuid4()}@example.com'
        assert client.post('/auth/register', json={'name': 'Teste WebSocket', 'email': email, 'password': 'senha12345'}).status_code == 201
        token = client.post('/auth/login', json={'email': email, 'password': 'senha12345'}).json()['access_token']
        client.headers['Authorization'] = 'Bearer ' + token
        with connect(os.getenv('ALERTS_WS_URL', 'ws://localhost:8001/ws/alerts')) as socket:
            socket.send(json.dumps({'token': token}))
            assert json.loads(socket.recv(timeout=15))['type'] == 'authenticated'
            socket.send(json.dumps({'type': 'location.update', 'latitude': 0, 'longitude': 0, 'radius_meters': 3000}))
            while json.loads(socket.recv(timeout=15))['type'] != 'snapshot':
                pass
            report = {'id': str(uuid4()), 'type': 'HEAT', 'description': 'DADO DE TESTE WebSocket resolução',
                      'latitude': 0, 'longitude': 0, 'accuracy_meters': 10,
                      'observed_at': datetime.now(timezone.utc).isoformat()}
            assert client.post('/reports', json=report).status_code == 202
            while True:
                event = json.loads(socket.recv(timeout=15))
                if event['type'] == 'report.created' and event['report']['id'] == report['id']:
                    break
            assert client.post('/reports/' + report['id'] + '/resolve').status_code == 200
            while True:
                event = json.loads(socket.recv(timeout=15))
                if event['type'] == 'report.removed' and event['report_id'] == report['id']:
                    assert event['status'] == 'RESOLVED'
                    break
            socket.send(json.dumps({'type': 'location.update', 'latitude': 0, 'longitude': 0, 'radius_meters': 3000}))
            while True:
                event = json.loads(socket.recv(timeout=15))
                if event['type'] == 'snapshot':
                    assert not any(row['id'] == report['id'] for row in event['reports'])
                    break
