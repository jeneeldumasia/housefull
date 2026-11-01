"""Create local emulator topics. Terraform owns these on GCP."""
from google.api_core.exceptions import AlreadyExists
from google.cloud import pubsub_v1

from houseful.config import PROJECT_ID, PUBSUB_TOPIC

PUSH_ENDPOINT = "http://worker:8080/pubsub/push"


def main() -> None:
    publisher = pubsub_v1.PublisherClient()
    subscriber = pubsub_v1.SubscriberClient()
    topic = publisher.topic_path(PROJECT_ID, PUBSUB_TOPIC)
    subscription = subscriber.subscription_path(PROJECT_ID, f"{PUBSUB_TOPIC}-worker")
    try:
        publisher.create_topic(name=topic)
    except AlreadyExists:
        pass
    try:
        subscriber.create_subscription(
            name=subscription,
            topic=topic,
            push_config=pubsub_v1.types.PushConfig(push_endpoint=PUSH_ENDPOINT),
        )
    except AlreadyExists:
        pass


if __name__ == "__main__":
    main()
