# Housefull build log

A record of every change to Housefull: what changed, why, how it works, and how to explain it in an interview. Newest entries are at the bottom.

## Current status

| Part | Status |
|---|---|
| App, UI, login, tests | Working on a laptop |
| GCP setup script | Run once from `main` |
| Branch protection | On for `main` |
| Terraform | Not started |
| GitHub Actions pipelines | Not started |
| Deployed on GCP | **No** |
| Load test numbers | None yet |

Only claim what's done. If this table says "not started", don't talk about it as finished.

## The project in 30 seconds

Housefull is an event ticket booking app. The app is deliberately small, because the point of the project is how it's deployed and run. It's built around the hardest moment for a booking site: sales open, thousands of people arrive at once, and two of them must never get the same seat.

---

## 1. Booking API and worker

**What changed:** a Python API (FastAPI), a separate worker, PostgreSQL, and Docker Compose to run it all locally, including a Pub/Sub emulator.

**Why two services:** taking a booking should be fast, but confirming it can take longer. The API reserves the seat and replies straight away. The worker confirms it afterwards. Each can scale and be released on its own.

**How a booking works:**
1. The API locks the seats and marks them `held`.
2. It creates a `pending` booking and publishes a message to Pub/Sub.
3. It commits, then replies with 202 (accepted, not finished yet).
4. Pub/Sub pushes the message to the worker.
5. The worker marks the booking `confirmed` and the seats `booked`.

**Key decisions:**
- **Publish before commit.** If publishing fails, the database rolls back and the seat is released. The catch is that the worker can receive the message before the commit is visible. It then returns 404, and Pub/Sub retries.
- **The worker ignores repeats.** Pub/Sub delivers messages at least once, so the same message can arrive twice. The worker only acts on a `pending` booking. This property is called idempotency.
- **Migrations are plain SQL files** applied once each, with a database lock so two runs can't collide.

**Likely questions:**
- *How do you stop two people getting the same seat?* The database decides. Only one transaction can lock an `available` seat, and a unique index is a second safety net. A test has 25 people try for one seat, and exactly one wins.
- *Why not check in Python first?* Two requests could both see the seat as free. The check and the update must be one database operation.
- *What's the weakness of publish before commit?* If the commit fails after publishing, a message exists for a booking that doesn't. The worker retries, gets 404 each time, and the message ends up in the dead-letter queue. The alternative is the outbox pattern, which is safer but more complex.

---

## 2. Web UI and login

**What changed:** a web UI served by the API, email and password login, and an admin role.

**Why the API serves the UI:** it's one less service to deploy. Static HTML, CSS, and JavaScript are enough here, so there's no separate frontend build.

**Key decisions:**
- **Argon2 for passwords.** It's designed to be slow and memory-heavy, which makes stolen hashes expensive to crack.
- **JWT in an HttpOnly cookie.** JavaScript can't read it, so a script injection attack can't steal it. `SameSite=Lax` blocks most cross-site request attacks.
- **Admins are granted by a command,** not at signup, so nobody can register as one.
- **Unknown emails take as long as wrong passwords,** and return the same message, so login can't be used to find out who has an account.
- **Other people's bookings return 404, not 403,** so booking ids can't be probed.

**Likely questions:**
- *What's the downside of a JWT?* It can't be cancelled before it expires. Sessions last 12 hours, and logout only clears the cookie in that browser.
- *Why not use Google login?* It's simpler for users, but email and password shows how authentication works and has no outside dependency.

---

## 3. Seat hold expiry and login limits

**What changed:** a scheduled job releases seats whose booking never got confirmed, and login attempts are now limited.

**Seat hold expiry:** if a message is lost, a seat would otherwise stay `held` forever. After 15 minutes, the job marks the booking `expired` and frees the seat. 15 minutes is longer than the Pub/Sub retry period, so a slow confirmation isn't cancelled. It uses `FOR UPDATE SKIP LOCKED` to leave alone any booking the worker is handling at that moment.

**Login limits:** 5 attempts per email and 30 per IP address every 15 minutes, then a 429 response. Successful logins don't count.

**Key decisions:**
- **Stored in PostgreSQL,** because Cloud Run runs many instances. A counter in memory would be separate for each one.
- **The attempt is counted before it's checked,** so parallel guesses can't all slip through.
- **Only the trusted part of `X-Forwarded-For` is used.** A caller can add fake addresses to the front, so the code reads from the end that Google's infrastructure sets.

**Likely questions:**
- *Can this be abused?* Yes. Someone can lock another person's email for up to 15 minutes. That's an accepted trade-off.
- *Why not Redis?* It would add a service to run. PostgreSQL is enough at this login volume.

---

## 4. Booking basics

**What changed:** event venue, description, and price, search, bookings of up to 6 seats, booking references, and cancellation.

**How multi-seat booking stays safe:** it's all or nothing. If one seat is taken, the whole booking fails and rolls back.

**Deadlock prevention:** if one person locks S1 then S2 while another locks S2 then S1, each waits forever. Seats are always locked in the same order (`ORDER BY id FOR UPDATE`), so that can't happen. A test runs overlapping bookings in opposite orders.

**Schema change:** a booking can now hold several seats, so a new `booking_seats` table links them. Its `active` flag frees a seat without losing the booking's history, and a partial unique index allows only one active booking per seat.

**Also added:** cancelling can race with the worker confirming. Both lock the booking row first, so they run one at a time, and a late message can't bring back a cancelled booking.

**Likely questions:**
- *Why a random reference and not the booking id?* Sequential ids reveal how many bookings exist and are easy to guess.
- *How was the migration tested?* An old-style booking was added to a database on the previous schema, then upgraded and checked.

---

## 5. Rename and custom domain plan

**What changed:** the project became Housefull. The GCP project ID stays `houseful`-based, because IDs can't be changed.

**Domain plan:** `housefull.jeneeldumasia.dev`, not built yet.

**Decision:** a global external load balancer, with Cloudflare for DNS only.
- Cloud Run's simple domain mapping isn't available in Mumbai (`asia-south1`), and Google marks it as Preview.
- Google recommends the load balancer. It provides a managed certificate, and lets Cloud Run refuse traffic that doesn't come through it.
- It costs money while running, so it only exists during demos.

**To do when this is built:** with a load balancer in front, the last `X-Forwarded-For` address is the load balancer itself, so `client_ip` must change or every user would share one login limit.

**Delivery rule:** the laptop is for development only. All infrastructure changes go through GitHub Actions, and secrets live in GitHub.

---

## 6. GCP bootstrap script

**What changed:** added `scripts/bootstrap_gcp.sh`, and ran it once from `main`.

**Why it exists:** GitHub Actions needs access to GCP before it can do anything, but that access has to be created first. This is the bootstrap problem. The script runs once, by hand, from a project owner's account. Terraform then takes these resources over, so later changes go through pull requests.

**What it creates:**
- The Google APIs the project needs.
- A Workload Identity pool that trusts tokens from GitHub, for this repo only.
- `housefull-plan`, a read-only account for previewing changes on pull requests.
- `housefull-deploy`, for making changes, usable only from `main`.

**How Workload Identity Federation works:**
1. A workflow asks GitHub for a short-lived signed token saying which repo and branch it's running from.
2. It sends that token to Google.
3. Google checks the signature and the repo id.
4. Google returns temporary credentials for the allowed service account.

**Key decisions:**
- **No service account keys.** A key lasts until someone deletes it, and could leak. These credentials expire by themselves.
- **Repo id, not repo name.** A name can be reused by someone else after a rename, and this project has already been renamed once. The id can't.
- **Two accounts.** A pull request can preview a change but can't make one.
- **The project ID is passed in as an argument,** so it stays out of the public code.

**Known risk:** `housefull-deploy` has broad access, and can change IAM within the project, so it could grant itself more. Terraform needs that to create everything. It's limited to this one project and to `main`, which is why `main` should be protected.

**Likely questions:**
- *Why wasn't this run through GitHub Actions?* Nothing could log in yet. The only alternative was a long-lived key in GitHub, which is what this setup avoids.
- *What stops a fork using it?* The pool rejects tokens from any other repo id, and GitHub doesn't pass secrets to pull requests from forks.
- *Is `housefull-deploy` least privilege?* Not strictly. It's limited by project and branch, and the roles could be narrowed later.

---

## 7. Branch protection and access checks

**What changed:** `main` now requires a pull request, and blocks force pushes and deletion. This applies to admins too. A new workflow, `verify-access.yml`, tests the login setup from inside GitHub Actions.

**Why branch protection:** whatever reaches `main` can use `housefull-deploy`, so `main` is effectively the key to the project. Protecting it is a security control as well as a tidy process.

**Why a test workflow:** a setup script finishing only proves resources exist. This proves the rules work, including the ones that should refuse access:
- The read-only account can read the project.
- The read-only account **can't** create anything.
- The deploy account **can't** be used from a pull request.
- The deploy account works from `main`.
- The Cloudflare and HCP Terraform tokens work.

**Key idea:** testing that access is denied matters as much as testing that it works. A security rule that's never been tested might not be working at all.

**Likely questions:**
- *You work alone, so why require pull requests?* Every change gets its automated checks and leaves a record. It also stops a mistaken push going straight to the branch that controls deployments.
- *No reviewer is required, so what's the protection?* Required approvals are 0, because GitHub doesn't let you approve your own pull request. Required status checks can be added once the pipeline exists.
