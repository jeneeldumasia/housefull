# Split from the subscription: services need the topic, and the subscription
# needs the worker's URL, so one module would depend on itself.
resource "google_pubsub_topic" "bookings" {
  name = "bookings"
}

output "topic_id" {
  value = google_pubsub_topic.bookings.id
}

output "topic_name" {
  value = google_pubsub_topic.bookings.name
}
