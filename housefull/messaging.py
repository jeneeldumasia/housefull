import json
from functools import lru_cache

from google.cloud import pubsub_v1

from housefull.config import PROJECT_ID, PUBSUB_TOPIC


class BookingPublisher:
    def __init__(self) -> None:
        self._client = pubsub_v1.PublisherClient()
        self._topic = self._client.topic_path(PROJECT_ID, PUBSUB_TOPIC)

    def publish(self, booking_id: int) -> None:
        data = json.dumps({"booking_id": booking_id}).encode()
        self._client.publish(self._topic, data).result(timeout=10)


@lru_cache
def get_publisher() -> BookingPublisher:
    return BookingPublisher()
