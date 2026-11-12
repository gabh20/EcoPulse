from pathlib import Path
import yaml

root = Path(__file__).resolve().parents[1]
services = {}
for index in range(1, 4):
    name = f"rabbit-{index}"
    services[name] = {
        "image": "rabbitmq:4-management", "hostname": name, "restart": "unless-stopped",
        "environment": {"RABBITMQ_ERLANG_COOKIE": "ecopulse-academic-cluster-cookie",
            "RABBITMQ_DEFAULT_USER": "ecopulse", "RABBITMQ_DEFAULT_PASS": "${RABBITMQ_PASSWORD:-ecopulse}"},
        "volumes": [f"{name}-data:/var/lib/rabbitmq", "./infra/rabbitmq-cluster.conf:/etc/rabbitmq/rabbitmq.conf:ro"],
        "healthcheck": {"test": ["CMD", "rabbitmq-diagnostics", "-q", "ping"], "interval": "10s", "timeout": "5s", "retries": 30},
    }
services["rabbit-1"]["ports"] = ["127.0.0.1:15673:15672"]
for index in range(1, 7):
    name = f"redis-{index}"
    services[name] = {
        "image": "redis:7-alpine", "restart": "unless-stopped",
        "command": ["redis-server", "--cluster-enabled", "yes", "--cluster-config-file", "nodes.conf",
                    "--cluster-node-timeout", "5000", "--appendonly", "yes"],
        "volumes": [f"{name}-data:/data"],
        "healthcheck": {"test": ["CMD", "redis-cli", "ping"], "interval": "5s", "timeout": "3s", "retries": 30},
    }
services["redis-init"] = {
    "image": "redis:7-alpine", "entrypoint": ["sh", "/setup.sh"],
    "volumes": ["./infra/redis-cluster-init.sh:/setup.sh:ro"],
    "depends_on": {f"redis-{i}": {"condition": "service_healthy"} for i in range(1,7)},
}
base = yaml.safe_load((root / "compose.yml").read_text(encoding="utf-8"))
services["postgres"] = base["services"]["postgres"]
dependencies = {"postgres": {"condition": "service_healthy"}, "redis-init": {"condition": "service_completed_successfully"},
                **{f"rabbit-{i}": {"condition": "service_healthy"} for i in range(1,4)}}
for name in ("api", "worker-0", "worker-1", "alerts"):
    service = base["services"][name]
    service["environment"] = {**service["environment"],
        "RABBITMQ_URLS": ",".join(f"amqp://ecopulse:${{RABBITMQ_PASSWORD:-ecopulse}}@rabbit-{i}:5672/" for i in range(1,4)),
        "RABBITMQ_QUORUM": "true", "REDIS_URL": "redis://redis-1:6379/0", "REDIS_CLUSTER": "true"}
    service["depends_on"] = dependencies
    services[name] = service
volumes = {"postgres-data": None, **{f"{name}-data": None for name in services if name.startswith(("rabbit-","redis-")) and name != "redis-init"}}
(root / "compose.cluster.yml").write_text(yaml.safe_dump({"name": "ecopulse-cluster", "services": services, "volumes": volumes}, sort_keys=False), encoding="utf-8")
print("compose.cluster.yml gerado")
