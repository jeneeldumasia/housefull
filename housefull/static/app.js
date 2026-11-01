const $ = (id) => document.getElementById(id);
const views = ["view-events", "view-seats", "view-bookings", "view-users"];
const BOOKING_LABELS = { pending: "Confirming", confirmed: "Confirmed", expired: "Expired", cancelled: "Cancelled" };
const MAX_SEATS = 6;
const money = (amount) => `₹${amount.toLocaleString("en-IN")}`;
const state = { user: null, event: null, seats: [], register: false, afterLogin: null };

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
  $("nav-users").hidden = !(user && user.is_admin);
  $("nav-logout").hidden = !user;
  $("nav-login").hidden = Boolean(user);
  $("event-form").hidden = !(user && user.is_admin);
}

async function loadEvents() {
  show("view-events");
  const list = $("event-list");
  const query = $("search").value.trim();
  const events = await api(`/events?q=${encodeURIComponent(query)}`);
  list.replaceChildren();
  if (!events.length) list.append(el("p", "", query ? "No events match your search." : "No events yet."));
  events.forEach((event) => {
    const card = el("button", "card");
    const full = event.available_seats === 0;
    card.append(
      el("strong", "", event.name),
      el("small", "", event.venue),
      el("small", "", `${when(event.starts_at)} · ${money(event.price_inr)}`),
      el("span", full ? "tag full" : "tag", full ? "HOUSEFULL" : `${event.available_seats} of ${event.total_seats} seats left`),
    );
    card.addEventListener("click", () => loadSeats(event.id));
    list.append(card);
  });
}

async function loadSeats(eventId) {
  const event = await api(`/events/${eventId}/seats`);
  state.event = event;
  state.seats = [];
  show("view-seats");
  $("seat-title").textContent = event.name;
  $("seat-when").textContent = `${event.venue} · ${when(event.starts_at)} · ${money(event.price_inr)} per seat`;
  $("seat-description").textContent = event.description;
  $("housefull-board").hidden = event.available.length > 0;
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
  if (state.seats.includes(label)) {
    state.seats = state.seats.filter((seat) => seat !== label);
    button.classList.remove("selected");
  } else if (state.seats.length < MAX_SEATS) {
    state.seats.push(label);
    button.classList.add("selected");
  } else {
    toast(`You can book up to ${MAX_SEATS} seats at a time.`);
  }
  renderBookButton();
}

function renderBookButton() {
  const count = state.seats.length;
  const button = $("book-button");
  button.disabled = count === 0;
  button.textContent = count ? `Book ${count} seat${count > 1 ? "s" : ""}` : "Select seats";
  $("seat-summary").textContent = count
    ? `${state.seats.join(", ")} · Total ${money(count * state.event.price_inr)}`
    : "";
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
      body: JSON.stringify({ seat_labels: state.seats }),
    });
    toast("Seats reserved. Confirming now.");
    await loadBookings();
  } catch (error) {
    if (error.status === 401) {
      state.user = null;
      renderNav();
      openAuth(book);
      return;
    }
    toast(error.status === 409 ? "Someone just took one of those seats. Pick again." : error.message);
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
      el("small", "", booking.venue),
      el("small", "", `Seats ${booking.seat_labels.join(", ")} · ${money(booking.total_inr)}`),
      el("div", "reference", booking.reference),
      el("span", ["expired", "cancelled"].includes(booking.status) ? "tag full" : "tag", BOOKING_LABELS[booking.status]),
    );
    if (booking.cancellable && ["pending", "confirmed"].includes(booking.status)) {
      const cancel = el("button", "link card-actions", "Cancel booking");
      cancel.addEventListener("click", () => cancelBooking(booking));
      card.append(cancel);
    }
    list.append(card);
  });
  clearTimeout(loadBookings.timer);
  if (bookings.some((booking) => booking.status === "pending")) {
    loadBookings.timer = setTimeout(() => {
      if (!$("view-bookings").hidden) loadBookings();
    }, 1500);
  }
}

async function cancelBooking(booking) {
  if (!window.confirm(`Cancel booking ${booking.reference}? Your seats will go back on sale.`)) return;
  try {
    await api(`/bookings/${booking.id}/cancel`, { method: "POST" });
    toast("Booking cancelled.");
  } catch (error) {
    toast(error.message);
  }
  await loadBookings();
}

async function loadUsers() {
  show("view-users");
  const list = $("user-list");
  const users = await api("/admin/users");
  list.replaceChildren();
  users.forEach((user) => {
    const card = el("div", "card");
    const isSelf = user.id === state.user.id;
    card.append(
      el("strong", "", user.email),
      el("small", "", `Joined ${when(user.created_at)}`),
      el("span", "tag", isSelf ? "Admin (you)" : user.is_admin ? "Admin" : "User"),
    );
    if (!isSelf) {
      const action = el("button", "link card-actions", user.is_admin ? "Revoke admin" : "Grant admin");
      action.addEventListener("click", () => changeAdmin(user));
      card.append(action);
    }
    list.append(card);
  });
}

async function changeAdmin(user) {
  if (user.is_admin && !window.confirm(`Remove admin rights from ${user.email}?`)) return;
  try {
    await api(`/admin/users/${user.id}/${user.is_admin ? "revoke" : "grant"}`, { method: "POST" });
    toast(user.is_admin ? "Admin rights removed." : "Admin rights granted.");
    await loadUsers();
  } catch (error) {
    toast(error.message);
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
$("search").addEventListener("input", () => {
  clearTimeout(loadEvents.timer);
  loadEvents.timer = setTimeout(loadEvents, 250);
});
$("nav-login").addEventListener("click", () => openAuth());
$("nav-bookings").addEventListener("click", loadBookings);
$("nav-users").addEventListener("click", loadUsers);
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
        venue: form.elements.venue.value,
        description: form.elements.description.value,
        price_inr: Number(form.elements.price_inr.value),
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
