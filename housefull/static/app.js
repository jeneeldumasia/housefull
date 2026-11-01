const $ = (id) => document.getElementById(id);
const views = ["view-events", "view-seats", "view-bookings", "view-users"];
const BOOKING_LABELS = { pending: "Confirming", confirmed: "Confirmed", expired: "Expired", cancelled: "Cancelled" };
const MAX_SEATS = 6;
const SEATS_PER_ROW = 10;
const LOW_SEAT_SHARE = 0.2;
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
    const fallback = res.status === 429
      ? "It's very busy right now. Please try again in a moment."
      : "Check what you entered and try again.";
    const error = new Error(typeof detail === "string" ? detail : fallback);
    error.status = res.status;
    throw error;
  }
  return body;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function show(view) {
  views.forEach((id) => { $(id).hidden = id !== view; });
  document.querySelectorAll(".nav-link").forEach((link) => {
    const current = link.getAttribute("href") === window.location.hash;
    if (current) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  });
}

function toast(message) {
  const node = $("toast");
  node.textContent = message;
  node.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { node.hidden = true; }, 4000);
}

function when(iso) {
  return new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

// Gives each event its own stable colours without needing uploaded artwork.
function posterColours(name) {
  const hash = [...name].reduce((total, char) => (total * 31 + char.codePointAt(0)) % 360, 7);
  return `linear-gradient(160deg, hsl(${hash} 72% 46%), hsl(${(hash + 48) % 360} 74% 28%))`;
}

function showError(list, message, retry) {
  const box = el("div", "empty");
  box.append(el("strong", "", "That didn't load"), el("p", "muted", message));
  const button = el("button", "ghost", "Try again");
  button.addEventListener("click", retry);
  box.append(button);
  list.replaceChildren(box);
}

function showEmpty(list, title, message, action) {
  const box = el("div", "empty");
  box.append(el("strong", "", title), el("p", "muted", message));
  if (action) box.append(action);
  list.replaceChildren(box);
}

function renderNav() {
  const user = state.user;
  $("nav-email").textContent = user ? user.email : "";
  $("nav-bookings").hidden = !user;
  $("nav-users").hidden = !(user && user.is_admin);
  $("nav-logout").hidden = !user;
  $("nav-login").hidden = Boolean(user);
  $("admin-panel").hidden = !(user && user.is_admin);
}

function eventCard(event) {
  const card = el("a", "event-card");
  card.href = `#/events/${event.id}`;
  const date = new Date(event.starts_at);
  const full = event.available_seats === 0;
  const low = !full && event.available_seats / event.total_seats <= LOW_SEAT_SHARE;
  if (full) card.classList.add("full");
  if (low) card.classList.add("low");

  const stub = el("div", "date-stub");
  stub.style.setProperty("--poster", posterColours(event.name));
  stub.append(
    el("span", "month", date.toLocaleString(undefined, { month: "short" }).toUpperCase()),
    el("span", "day", String(date.getDate())),
    el("span", "time", date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })),
  );

  const info = el("div", "event-info");
  const left = event.total_seats ? event.available_seats / event.total_seats : 0;
  const meter = el("div", "meter");
  const fill = el("i");
  fill.style.width = `${Math.round(left * 100)}%`;
  meter.append(fill);
  const foot = el("div", "foot");
  foot.append(
    el("span", "price", event.price_inr ? money(event.price_inr) : "Free"),
    el("span", "pill", full ? "" : low ? `Only ${event.available_seats} left` : `${event.available_seats} of ${event.total_seats} left`),
  );
  info.append(el("h3", "", event.name), el("span", "venue", event.venue), foot, meter);

  card.append(stub, info);
  if (full) card.append(el("span", "stamp", "HOUSEFULL"));
  card.setAttribute("aria-label", `${event.name}, ${event.venue}, ${when(event.starts_at)}, ${full ? "sold out" : `${event.available_seats} seats left`}`);
  return card;
}

async function loadEvents() {
  show("view-events");
  const list = $("event-list");
  const query = $("search").value.trim();
  if (!list.children.length) {
    list.replaceChildren(...[1, 2, 3].map(() => el("div", "skeleton")));
  }
  try {
    const events = await api(`/events?q=${encodeURIComponent(query)}`);
    $("events-count").textContent = events.length ? `${events.length} event${events.length > 1 ? "s" : ""}` : "";
    if (!events.length) {
      showEmpty(
        list,
        query ? "No matches" : "The stage is empty",
        query ? "Try a different event or venue." : "New events will appear here soon.",
      );
      return;
    }
    list.replaceChildren(...events.map(eventCard));
  } catch (error) {
    showError(list, error.message, loadEvents);
  }
}

function seatRowName(index) {
  return index < 26 ? String.fromCharCode(65 + index) : String(index + 1);
}

function seatButton(seat) {
  const number = seat.label.replace(/^S/, "");
  const button = el("button", "seat", number);
  button.dataset.label = seat.label;
  button.disabled = seat.status !== "available" || !state.event.bookable;
  button.title = `Seat ${seat.label}`;
  button.setAttribute("aria-label", `Seat ${seat.label}, ${seat.status}`);
  button.setAttribute("aria-pressed", "false");
  button.addEventListener("click", () => selectSeat(seat.label, button));
  return button;
}

function renderSeatGrid(seats) {
  const rows = [];
  for (let start = 0; start < seats.length; start += SEATS_PER_ROW) {
    const row = el("div", "seat-row");
    row.append(el("span", "row-label", seatRowName(rows.length)));
    seats.slice(start, start + SEATS_PER_ROW).forEach((seat, index) => {
      if (index === SEATS_PER_ROW / 2) row.append(el("span", "aisle"));
      row.append(seatButton(seat));
    });
    rows.push(row);
  }
  $("seat-grid").replaceChildren(...rows);
}

async function loadSeats(eventId) {
  let event;
  try {
    event = await api(`/events/${eventId}/seats`);
  } catch (error) {
    toast(error.status === 404 ? "That event doesn't exist." : error.message);
    window.location.hash = "#/";
    return;
  }
  state.event = event;
  state.seats = [];
  show("view-seats");
  const soldOut = event.available.length === 0;
  document.title = `${event.name} | Housefull`;
  $("seat-title").textContent = event.name;
  $("seat-when").textContent = `${event.venue} · ${when(event.starts_at)} · ${event.price_inr ? `${money(event.price_inr)} per seat` : "Free"}`;
  $("seat-description").textContent = event.description;
  $("seat-poster").style.setProperty("--poster", posterColours(event.name));
  $("housefull-board").hidden = !soldOut;
  $("started-note").hidden = event.bookable;
  renderSeatGrid(event.seats);
  renderOrder();
  window.scrollTo(0, 0);
}

function selectSeat(label, button) {
  if (state.seats.includes(label)) {
    state.seats = state.seats.filter((seat) => seat !== label);
    button.classList.remove("selected");
    button.setAttribute("aria-pressed", "false");
  } else if (state.seats.length < MAX_SEATS) {
    state.seats.push(label);
    button.classList.add("selected");
    button.setAttribute("aria-pressed", "true");
  } else {
    toast(`You can book up to ${MAX_SEATS} seats at a time.`);
  }
  renderOrder();
}

function renderOrder() {
  const count = state.seats.length;
  const button = $("book-button");
  const event = state.event;
  const open = event.bookable && event.available.length > 0;
  button.hidden = !open;
  button.disabled = count === 0;
  button.textContent = count ? `Book ${count} seat${count > 1 ? "s" : ""}` : "Select seats";
  $("order-count").textContent = String(count);
  $("seat-summary").textContent = money(count * event.price_inr);
  $("seat-chips").replaceChildren(
    ...(count
      ? state.seats.map((seat) => el("span", "chip", seat))
      : [el("p", "muted", open ? `Pick up to ${MAX_SEATS} seats.` : "No seats are available.")]),
  );
}

async function book() {
  if (!state.user) {
    openAuth(book);
    return;
  }
  const eventId = state.event.id;
  const button = $("book-button");
  button.disabled = true;
  button.textContent = "Booking...";
  try {
    await api(`/events/${eventId}/bookings`, {
      method: "POST",
      body: JSON.stringify({ seat_labels: state.seats }),
    });
    toast("Seats reserved. Confirming now.");
    window.location.hash = "#/bookings";
  } catch (error) {
    if (error.status === 401) {
      state.user = null;
      renderNav();
      renderOrder();
      openAuth(book);
      return;
    }
    toast(error.status === 409 ? "Someone just took one of those seats. Pick again." : error.message);
    await loadSeats(eventId);
  }
}

// Decorative only. The same reference always draws the same pattern.
function barcode(reference) {
  const bars = el("div", "barcode");
  bars.setAttribute("aria-hidden", "true");
  [...reference, ...reference].forEach((char) => {
    const bar = el("i");
    bar.style.width = `${1 + (char.charCodeAt(0) % 3)}px`;
    bars.append(bar);
  });
  return bars;
}

function ticketFact(label, value) {
  const fact = el("div");
  fact.append(el("span", "", label), document.createTextNode(value));
  return fact;
}

function ticket(booking) {
  const card = el("article", `ticket ${booking.status}`);
  const main = el("div", "ticket-main");
  const facts = el("div", "ticket-facts");
  facts.append(
    ticketFact("When", when(booking.starts_at)),
    ticketFact(booking.seat_labels.length > 1 ? "Seats" : "Seat", booking.seat_labels.join(", ")),
    ticketFact("Total", booking.total_inr ? money(booking.total_inr) : "Free"),
  );
  main.append(el("h3", "", booking.event_name), el("p", "muted", booking.venue), facts);

  const side = el("div", "ticket-side");
  side.append(
    barcode(booking.reference),
    el("span", "reference", booking.reference),
    el("span", "status", BOOKING_LABELS[booking.status]),
  );
  if (booking.cancellable && ["pending", "confirmed"].includes(booking.status)) {
    const cancel = el("button", "link", "Cancel booking");
    cancel.addEventListener("click", () => cancelBooking(booking));
    side.append(cancel);
  }
  card.append(main, side);
  return card;
}

async function loadBookings() {
  if (!state.user) {
    window.location.hash = "#/";
    openAuth(() => { window.location.hash = "#/bookings"; });
    return;
  }
  show("view-bookings");
  const list = $("booking-list");
  clearTimeout(loadBookings.timer);
  try {
    const bookings = await api("/me/bookings");
    if (!bookings.length) {
      const browse = el("button", "", "Browse events");
      browse.addEventListener("click", () => { window.location.hash = "#/"; });
      showEmpty(list, "No tickets yet", "When you book a seat, your ticket will be here.", browse);
      return;
    }
    list.replaceChildren(...bookings.map(ticket));
    if (bookings.some((booking) => booking.status === "pending")) {
      loadBookings.timer = setTimeout(() => {
        if (!$("view-bookings").hidden) loadBookings();
      }, 1500);
    }
  } catch (error) {
    showError(list, error.message, loadBookings);
  }
}

function askToConfirm(title, body, action) {
  return new Promise((resolve) => {
    const dialog = $("confirm-dialog");
    $("confirm-title").textContent = title;
    $("confirm-body").textContent = body;
    $("confirm-yes").textContent = action;
    dialog.returnValue = "no";
    dialog.addEventListener("close", () => resolve(dialog.returnValue === "yes"), { once: true });
    dialog.showModal();
  });
}

async function cancelBooking(booking) {
  const sure = await askToConfirm(
    "Cancel this booking?",
    `${booking.reference} will be cancelled and your seats will go back on sale.`,
    "Cancel booking",
  );
  if (!sure) return;
  try {
    await api(`/bookings/${booking.id}/cancel`, { method: "POST" });
    toast("Booking cancelled.");
  } catch (error) {
    toast(error.message);
  }
  await loadBookings();
}

function userRow(user) {
  const row = el("div", "user-row");
  const isSelf = user.id === state.user.id;
  const avatar = el("span", "avatar", user.email[0]);
  avatar.style.setProperty("--poster", posterColours(user.email));
  const text = el("div", "user-text");
  text.append(el("strong", "", user.email), el("small", "", `Joined ${when(user.created_at)}`));
  row.append(
    avatar,
    text,
    el("span", user.is_admin ? "role admin" : "role", isSelf ? "Admin (you)" : user.is_admin ? "Admin" : "User"),
  );
  if (!isSelf) {
    const action = el("button", "ghost small", user.is_admin ? "Revoke admin" : "Grant admin");
    action.addEventListener("click", () => changeAdmin(user));
    row.append(action);
  }
  return row;
}

async function loadUsers() {
  if (!state.user || !state.user.is_admin) {
    window.location.hash = "#/";
    return;
  }
  show("view-users");
  const list = $("user-list");
  try {
    const users = await api("/admin/users");
    const admins = users.filter((user) => user.is_admin).length;
    $("user-count").textContent = `${users.length} user${users.length > 1 ? "s" : ""}, ${admins} admin${admins > 1 ? "s" : ""}`;
    list.replaceChildren(...users.map(userRow));
  } catch (error) {
    showError(list, error.message, loadUsers);
  }
}

async function changeAdmin(user) {
  if (user.is_admin) {
    const sure = await askToConfirm(
      "Remove admin rights?",
      `${user.email} will lose admin access straight away.`,
      "Revoke admin",
    );
    if (!sure) return;
  }
  try {
    await api(`/admin/users/${user.id}/${user.is_admin ? "revoke" : "grant"}`, { method: "POST" });
    toast(user.is_admin ? "Admin rights removed." : "Admin rights granted.");
    await loadUsers();
  } catch (error) {
    toast(error.message);
  }
}

function renderAuthMode() {
  $("auth-title").textContent = state.register ? "Create your account" : "Welcome back";
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

function route() {
  clearTimeout(loadBookings.timer);
  document.title = "Housefull | Book your seat before it's gone";
  const hash = window.location.hash;
  const event = hash.match(/^#\/events\/(\d+)$/);
  if (event) return loadSeats(event[1]);
  if (hash === "#/bookings") return loadBookings();
  if (hash === "#/users") return loadUsers();
  return loadEvents();
}

$("auth-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.target;
  const submit = $("auth-submit");
  submit.disabled = true;
  try {
    state.user = await api(state.register ? "/auth/register" : "/auth/login", {
      method: "POST",
      body: JSON.stringify({ email: form.email.value, password: form.password.value }),
    });
  } catch (error) {
    $("auth-error").textContent = error.message;
    $("auth-error").hidden = false;
    return;
  } finally {
    submit.disabled = false;
  }
  form.reset();
  $("auth-dialog").close();
  renderNav();
  const next = state.afterLogin;
  state.afterLogin = null;
  if (next) await next();
  else if (!$("view-events").hidden) await loadEvents();
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
$("book-button").addEventListener("click", book);
$("nav-logout").addEventListener("click", async () => {
  await api("/auth/logout", { method: "POST" });
  state.user = null;
  renderNav();
  window.location.hash = "#/";
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
    $("admin-panel").open = false;
    toast("Event created.");
    await loadEvents();
  } catch (error) {
    toast(error.message);
  }
});
window.addEventListener("hashchange", route);

(async () => {
  try {
    state.user = await api("/auth/me");
  } catch {
    state.user = null;
  }
  renderNav();
  await route();
})();
