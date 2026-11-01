const $ = (id) => document.getElementById(id);
const views = ["view-events", "view-seats", "view-bookings"];
const BOOKING_LABELS = { pending: "Confirming", confirmed: "Confirmed", expired: "Expired" };
const state = { user: null, event: null, seat: null, register: false, afterLogin: null };

async function api(path, options = {}) {
  const res = await fetch(path, {
    ...options,
    headers: options.body ? { "Content-Type": "application/json" } : {},
  });
  const body = res.status === 204 ? null : await res.json().catch(() => null);
  if (!res.ok) {
    const detail = body && body.detail;
    const error = new Error(typeof detail === "string" ? detail : "Check what you entered and try again.");
    error.status = res.status;
    throw error;
  }
  return body;
}

function show(view) {
  views.forEach((id) => { $(id).hidden = id !== view; });
}

function toast(message) {
  const el = $("toast");
  el.textContent = message;
  el.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { el.hidden = true; }, 3500);
}

function when(iso) {
  return new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function renderNav() {
  const user = state.user;
  $("nav-email").textContent = user ? user.email : "";
  $("nav-bookings").hidden = !user;
  $("nav-logout").hidden = !user;
  $("nav-login").hidden = Boolean(user);
  $("event-form").hidden = !(user && user.is_admin);
}

async function loadEvents() {
  show("view-events");
  const list = $("event-list");
  const events = await api("/events");
  list.replaceChildren();
  if (!events.length) list.append(el("p", "muted", "No events yet."));
  events.forEach((event) => {
    const card = el("button", "card");
    const full = event.available_seats === 0;
    card.append(
      el("strong", "", event.name),
      el("small", "", when(event.starts_at)),
      el("span", full ? "tag full" : "tag", full ? "HOUSEFUL" : `${event.available_seats} of ${event.total_seats} seats left`),
    );
    card.addEventListener("click", () => loadSeats(event.id));
    list.append(card);
  });
}

async function loadSeats(eventId) {
  const event = await api(`/events/${eventId}/seats`);
  state.event = event;
  state.seat = null;
  show("view-seats");
  $("seat-title").textContent = event.name;
  $("seat-when").textContent = when(event.starts_at);
  $("houseful-board").hidden = event.available.length > 0;
  $("book-button").hidden = event.available.length === 0;
  const grid = $("seat-grid");
  grid.replaceChildren();
  event.seats.forEach((seat) => {
    const button = el("button", "seat", seat.label);
    button.disabled = seat.status !== "available";
    button.setAttribute("aria-label", `Seat ${seat.label}, ${seat.status}`);
    button.addEventListener("click", () => selectSeat(seat.label, button));
    grid.append(button);
  });
  renderBookButton();
}

function selectSeat(label, button) {
  document.querySelectorAll(".seat.selected").forEach((seat) => seat.classList.remove("selected"));
  state.seat = label;
  button.classList.add("selected");
  renderBookButton();
}

function renderBookButton() {
  const button = $("book-button");
  button.disabled = !state.seat;
  button.textContent = state.seat ? `Book seat ${state.seat}` : "Select a seat";
}

async function book() {
  if (!state.user) {
    openAuth(book);
    return;
  }
  const eventId = state.event.id;
  try {
    await api(`/events/${eventId}/bookings`, {
      method: "POST",
      body: JSON.stringify({ seat_label: state.seat }),
    });
    toast(`Seat ${state.seat} reserved. Confirming now.`);
    await loadBookings();
  } catch (error) {
    if (error.status === 401) {
      state.user = null;
      renderNav();
      openAuth(book);
      return;
    }
    toast(error.status === 409 ? "Someone just took that seat. Pick another." : error.message);
    await loadSeats(eventId);
  }
}

async function loadBookings() {
  show("view-bookings");
  const list = $("booking-list");
  const bookings = await api("/me/bookings");
  list.replaceChildren();
  if (!bookings.length) list.append(el("p", "muted", "You have no bookings yet."));
  bookings.forEach((booking) => {
    const card = el("div", "card");
    card.append(
      el("strong", "", booking.event_name),
      el("small", "", when(booking.starts_at)),
      el("small", "", `Seat ${booking.seat_label}`),
      el("span", booking.status === "expired" ? "tag full" : "tag", BOOKING_LABELS[booking.status]),
    );
    list.append(card);
  });
  clearTimeout(loadBookings.timer);
  if (bookings.some((booking) => booking.status === "pending")) {
    loadBookings.timer = setTimeout(() => {
      if (!$("view-bookings").hidden) loadBookings();
    }, 1500);
  }
}

function renderAuthMode() {
  $("auth-title").textContent = state.register ? "Create your account" : "Log in";
  $("auth-submit").textContent = state.register ? "Create account" : "Log in";
  $("auth-switch").textContent = state.register ? "Already registered? Log in" : "New here? Create an account";
  $("auth-form").password.autocomplete = state.register ? "new-password" : "current-password";
}

function openAuth(afterLogin = null) {
  state.afterLogin = afterLogin;
  $("auth-error").hidden = true;
  renderAuthMode();
  $("auth-dialog").showModal();
}

$("auth-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.target;
  try {
    state.user = await api(state.register ? "/auth/register" : "/auth/login", {
      method: "POST",
      body: JSON.stringify({ email: form.email.value, password: form.password.value }),
    });
  } catch (error) {
    $("auth-error").textContent = error.message;
    $("auth-error").hidden = false;
    return;
  }
  form.reset();
  $("auth-dialog").close();
  renderNav();
  const next = state.afterLogin;
  state.afterLogin = null;
  if (next) await next();
});

$("auth-switch").addEventListener("click", () => {
  state.register = !state.register;
  $("auth-error").hidden = true;
  renderAuthMode();
});
$("auth-cancel").addEventListener("click", () => $("auth-dialog").close());
$("nav-login").addEventListener("click", () => openAuth());
$("nav-bookings").addEventListener("click", loadBookings);
$("book-button").addEventListener("click", book);
$("home").addEventListener("click", (event) => {
  event.preventDefault();
  loadEvents();
});
$("nav-logout").addEventListener("click", async () => {
  await api("/auth/logout", { method: "POST" });
  state.user = null;
  renderNav();
  await loadEvents();
});
$("event-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.target;
  try {
    await api("/events", {
      method: "POST",
      body: JSON.stringify({
        name: form.elements.name.value,
        starts_at: new Date(form.elements.starts_at.value).toISOString(),
        seats: Number(form.elements.seats.value),
      }),
    });
    form.reset();
    toast("Event created.");
    await loadEvents();
  } catch (error) {
    toast(error.message);
  }
});

(async () => {
  try {
    state.user = await api("/auth/me");
  } catch {
    state.user = null;
  }
  renderNav();
  await loadEvents();
})();
