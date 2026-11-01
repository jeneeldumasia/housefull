import os

DATABASE_URL = os.environ["DATABASE_URL"]
PROJECT_ID = os.environ["GOOGLE_CLOUD_PROJECT"]
PUBSUB_TOPIC = os.environ.get("PUBSUB_TOPIC", "bookings")
