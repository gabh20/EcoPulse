import asyncio
import json
import logging
import aio_pika
from .config import settings

log = logging.getLogger(__name__)
QUEUES = ("reports.0", "reports.1", "alerts")
DELAYS = (5000, 15000, 30000)


async def connect():
    last_error = None
    for url in settings().rabbitmq_urls.split(","):
        try:
            return await aio_pika.connect(url.strip(), timeout=5)
        except Exception as error:
            last_error = error
    raise ConnectionError("Nenhum nó RabbitMQ está acessível.") from last_error


async def topology(channel):
    arguments = {"x-queue-type": "quorum", "x-delivery-limit": -1} if settings().rabbitmq_quorum else {}
    for name in QUEUES:
        await channel.declare_queue(name, durable=True, arguments=arguments)
        await channel.declare_queue(name + ".dead", durable=True, arguments=arguments)
        for attempt, delay in enumerate(DELAYS, start=1):
            await channel.declare_queue(name + f".retry.{attempt}", durable=True, arguments={
                **arguments, "x-message-ttl": delay,
                "x-dead-letter-exchange": "", "x-dead-letter-routing-key": name,
                **({"x-dead-letter-strategy": "at-least-once", "x-overflow": "reject-publish"}
                   if settings().rabbitmq_quorum else {}),
            })


async def send(channel, queue, body, attempt=0):
    message = aio_pika.Message(
        body=json.dumps(body).encode(), content_type="application/json",
        delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
        headers={"attempt": attempt},
    )
    await channel.default_exchange.publish(message, routing_key=queue, mandatory=True, timeout=10)


async def publish(queue, body):
    connection = await connect()
    async with connection:
        channel = await connection.channel(publisher_confirms=True, on_return_raises=True)
        await topology(channel)
        await send(channel, queue, body)


async def consume(queue_name, handler, on_dead=None):
    while True:
        try:
            connection = await connect()
            async with connection:
                channel = await connection.channel(publisher_confirms=True, on_return_raises=True)
                await channel.set_qos(prefetch_count=1)
                await topology(channel)
                queue = await channel.get_queue(queue_name)
                async with queue.iterator() as messages:
                    async for message in messages:
                        try:
                            await handler(json.loads(message.body))
                        except Exception:
                            log.exception("Falha no processamento de %s", queue_name)
                            attempt = int(message.headers.get("attempt", 0))
                            target = queue_name + (f".retry.{attempt + 1}" if attempt < 3 else ".dead")
                            retry = aio_pika.Message(body=message.body,
                                delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
                                headers={"attempt": attempt + 1})
                            await channel.default_exchange.publish(retry, routing_key=target, mandatory=True, timeout=10)
                            if attempt >= 3 and on_dead:
                                try:
                                    await on_dead(message.body)
                                except Exception:
                                    log.exception("Estado de falha não atualizado; mensagem preservada na DLQ")
                        await message.ack()
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Consumidor desconectado; nova conexão em 5 segundos")
            await asyncio.sleep(5)
