# Housefull build log

A record of every change to Housefull: what changed, why, how it works, and how to explain it in an interview. Newest entries are at the bottom.

## Current status

| Part | Status |
|---|---|
| App, UI, login, tests | Working on a laptop |
| GCP setup script | Run once from `main` |
| Branch protection | On for `main` |
| Private Grafana | Live behind the Wag VPN, device enrolled, all charts confirmed |
| Terraform | Applied through GitHub Actions |
| GitHub Actions pipelines | Up and gradual release work; rollback and Down **not tested yet** |
| Deployed on GCP | **Yes, live** |
| Load test | Done, see `docs/load-test.md` |

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

**Login limits and the load balancer:** see entry 8.

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

**Two mistakes this caught:**
- The first Cloudflare check failed with a 401, but the token was fine. Cloudflare's verify call rejects account-owned tokens, so the check was changed to the zone lookup the deployment really needs.
- The "deploy account is refused" check first passed on any failure, so it could have passed because something else broke. It now requires Google's specific permission error. A negative test has to check why something failed.

**Likely questions:**
- *You work alone, so why require pull requests?* Every change gets its automated checks and leaves a record. It also stops a mistaken push going straight to the branch that controls deployments.
- *No reviewer is required, so what's the protection?* Required approvals are 0, because GitHub doesn't let you approve your own pull request. Required status checks can be added once the pipeline exists.

---

## 8. Terraform

**What changed:** all the infrastructure is now written as Terraform in `terraform/`, and pull requests run `terraform plan` in GitHub Actions. **Nothing has been applied, so none of this exists on GCP yet.**

**Who does what:** code is written on a laptop and merged by pull request. Terraform only runs in GitHub Actions. State is stored in HCP Terraform, in local execution mode: HCP keeps the state and the lock, and the run happens in GitHub Actions, where the Workload Identity login is.

**Two stacks:**
- `terraform/access`: the Workload Identity pool and CI service accounts, imported from the bootstrap script.
- `terraform/app`: everything else.

They're separate so that destroying the app after a demo can never remove the access needed to bring it back.

**What `terraform/app` creates:**

| Module | Creates | Why |
|---|---|---|
| `network` | VPC, subnet, peering to Google's network | Gives the database a private address |
| `database` | Cloud SQL PostgreSQL, user, connection secret | No public IP, and encrypted connections only |
| `messaging` | Pub/Sub topic, subscription, dead-letter topic | Retries 5 times, then keeps the failed message |
| `services` | API, worker, migration and expiry jobs, schedule, service accounts, JWT secret | One identity per job |
| `edge` | Load balancer, certificate, DNS record | HTTPS on `housefull.jeneeldumasia.dev` |

**Request path:** browser, Cloudflare DNS lookup, Google load balancer, API on Cloud Run, database over the private network.

**Key decisions:**
- **Connection limits are calculated.** The smallest database allows about 25 connections. Instance limits and pool sizes are set so the most we can open is 20: 3 API instances with 4 each, 2 workers with 3 each, plus 2 for jobs. Without this, autoscaling would overload the database under traffic.
- **The API only accepts traffic from the load balancer,** so the `run.app` address is refused.
- **`invoker_iam_disabled` instead of `allUsers`.** The ingress rule already restricts access, and organization policies often block `allUsers`.
- **The worker accepts internal traffic only,** and only the Pub/Sub identity can call it. Pub/Sub signs each request with an OIDC token.
- **Cloudflare is DNS only,** so the load balancer sees the real client address and Google can issue the certificate.
- **The database name has a random suffix,** because Cloud SQL names can't be reused for about a week, and this one gets destroyed between demos.
- **Backups are off,** because this is demo data. That wouldn't be right for a real service, and it's worth saying so.
- **Secret values are in Terraform state.** The generated passwords must exist somewhere, so state needs to be protected. It's held in HCP Terraform, not in the repo.

**Login limits changed:** behind a load balancer, the last `X-Forwarded-For` address isn't the user. The load balancer now sets its own `X-Client-IP` header, and the app reads that. Every user would otherwise have shared one IP limit. This still needs checking on the live site.

**Chicken and egg:**
- The subscription needs the worker's URL, and the worker's service needs the topic. So the topic has its own small module, which breaks the cycle.
- Cloud Run needs an image, but the registry that stores it is created by the same Terraform. The first run uses Google's sample image, then CI swaps in the real one.

**Likely questions:**
- *How does Cloud Run reach a private database?* Direct VPC egress gives instances an address in the subnet, and the subnet reaches Cloud SQL through peering.
- *What happens if Terraform state is lost?* Terraform forgets what it manages. Everything has to be imported again, which is why state is stored remotely with locking.
- *Why not put the database password straight in an environment variable?* It would be visible in the service configuration. Secret Manager keeps it out, and only named service accounts can read it.
- *What's the single point of failure?* The database. It's one small instance in one zone. A real service would use high availability and backups.
- *Why is this split into modules?* Each one has a clear job, and could be reused for another environment.

---

## 9. Deploy workflows

**What changed:** four workflows and two scripts. Up has since been run. See entries 10 to 12.

| Workflow | Runs when | What it does |
|---|---|---|
| `tests.yml` | Pull request | App tests |
| `terraform-plan.yml` | Pull request touching Terraform | Previews changes with the read-only account |
| `deploy.yml` | Merge to `main`, or run by hand (Up) | Updates CI access, then releases |
| `down.yml` | Run by hand, must type `DOWN` | Destroys the app and its data |

**Merging never starts costs.** A merge always updates CI access, which is free. It only releases the app if the app is already running. Running `deploy.yml` by hand is the Up button.

**Release order:**
1. Run the tests.
2. Build the image and scan it with Trivy. A critical vulnerability with a fix available stops the release.
3. Apply Terraform.
4. Push the image, tagged with the commit SHA.
5. Run migrations as a Cloud Run job.
6. Release the API gradually.
7. Release the worker.
8. Wait for the public site.

Everything risky comes after the cheap checks, so a failed test or scan costs nothing.

**Gradual release in `scripts/release_api.sh`:**
1. Deploy the new version with 0% traffic. If it fails its startup check, the release stops.
2. Move 10% of traffic to it.
3. Send 200 requests, and check the logs for server errors from the new version.
4. Check that it served at least one request. Zero would mean it was never tested.
5. Any failure sends all traffic back to the old version. Otherwise it gets 100%.

**Key decisions:**
- **Terraform owns configuration, CI owns releases.** `ignore_changes` stops Terraform undoing the running image or traffic split.
- **Migrations run before code,** and must work with both versions. **A rollback doesn't undo a migration,** because old code keeps running on the new schema. So changes must be backward compatible.
- **No hidden-URL test.** Cloud Run's tagged URLs follow the same ingress rule, so the load-balancer-only API can't be reached that way. That's why it's tested with a small share of real traffic.
- **`/healthz` became `/health`,** because Cloud Run reserves `/healthz` on public URLs.
- **Trivy runs from a pinned Docker image,** so a moved tag on a third-party GitHub Action can't change what runs.
- **The first release skips the gradual step,** because nothing is running yet and the certificate may not be ready.
- **Runs can't overlap.** A shared concurrency group stops two runs changing infrastructure together.

**Known limits:**
- Only `/health` is tested during the 10% stage, so a bug in booking wouldn't be caught there.
- The worker is released directly, with no gradual step or automatic rollback.
- Down may fail on its first try. Google can hold subnet addresses for a while after Cloud Run is deleted. Rerun it later if so.

**Likely questions:**
- *What happens if a migration fails?* The job fails, the workflow stops, and the running version isn't touched.
- *What happens to users during a rollback?* About 10% of requests hit the bad version for a short time, then all traffic returns to the old one.
- *Why tag images with the commit SHA?* You can always tell exactly what code is running, and `latest` can't tell you that.
- *Why is scanning only blocking on critical issues?* Blocking on everything would stop releases for problems that have no fix yet.

---

## 10. First Up attempt: the scanner blocked a release

**What happened:** the first Up stopped at the image scan. Trivy found a critical vulnerability, CVE-2026-102268, in PyJWT 2.9.0. Nothing had been created on GCP, because scanning runs before Terraform.

**Fix:** upgraded PyJWT to 2.14.0, the fixed version, then re-ran the tests and the scan.

**Why it mattered:** the flaw is about public key validation. Housefull signs tokens with a shared secret (HS256), so it probably wasn't exploitable here. It was upgraded anyway, because an unused flaw can become a real one, and arguing with a scanner is how exceptions pile up.

**Likely question:**
- *Has your pipeline ever stopped a bad release?* Yes, on its first run. It blocked a critical CVE in a dependency before any infrastructure was created, and the fix was a one-line version bump through a pull request.

---

## 11. Second Up attempt: a wrong header variable

**What happened:** Terraform created 45 resources, including the database and both services, then failed on the load balancer's backend. Google rejected `{client_ip}` as a header variable.

**Cause:** the variable name was assumed, not checked. `terraform plan` and `terraform validate` passed, because only Google checks that value when the resource is created. The correct name is `{client_ip_address}`.

**Why re-running is safe:** Terraform stores what it has already created in state, so the next apply only creates what's missing.

**Likely question:**
- *Does a clean plan mean an apply will work?* No. A plan compares your code with the current state. Many values are only checked by the cloud API at creation, which is why a failed apply needs to be safe to re-run.

---

## 12. Getting ready to stay online

**What changed:** five fixes for leaving the site public, and a release safety check.

| Risk | Fix |
|---|---|
| Open sign-ups | Sign-ups close at 200 accounts, so abuse has a limit. Emails still aren't verified, because that needs an email provider. |
| No admin | `grant-admin.yml` runs a Cloud Run job to promote a registered user. |
| No backups | Daily automated Cloud SQL backups, kept for 7 days. Down deletes them too. |
| No alerts | Email alerts for the site being down, repeated server errors, and bookings in the dead-letter queue. |
| Seat expiry job | Runs every 15 minutes, not every 5, because holds last 15 minutes anyway. |

**A correction:** the expiry job doesn't wake the database. Cloud SQL runs all the time. Cloud Run is what scales to zero.

**Release safety:** the gradual release tests through the public address. If the certificate wasn't ready, every request would fail, and a healthy release would be rolled back. It now waits for the site first, and leaves traffic alone if the site never comes up.

**Likely questions:**
- *How would you know if the site went down?* A Cloud Monitoring uptime check calls `/health` from several locations and emails an alert.
- *Why alert on the dead-letter queue?* A message only lands there after 5 failed attempts, so one message means a customer's booking wasn't confirmed.
- *Are the backups tested?* No. A backup you've never restored is only a hope, and a real service would test restores.

---

## 13. Admin user management

**What changed:** admins now have a Users page listing every account, with buttons to grant or remove admin rights. It's backed by `GET /admin/users` and `POST /admin/users/{id}/grant` or `/revoke`. Tested locally and in a real browser. **Not on the live site until this is merged and deployed.**

**Why:** the Grant admin workflow can add an admin, but it can't remove one, and it needs GitHub access. Everyday account management belongs in the app. The workflow stays for the first admin, because the page needs an admin to open it.

**How it works:**
- Only admins can reach these routes. Everyone else gets 401 or 403.
- The list returns only id, email, admin status, and join date. It never returns password hashes.
- A revoke takes effect on the person's next request, because `current_user` reads `is_admin` from the database every time. It isn't stored in their login token.
- Repeating a grant or revoke changes nothing and returns success.

**Keeping at least one admin:** an admin can't remove their own rights, so whoever revokes someone always remains an admin. Two admins revoking each other at the same moment could still remove both, so a revoke locks all admin rows first. The second request then waits, sees it's no longer an admin, and gets 403. A test repeats this race, and exactly one admin is left each time.

**Known limits:**
- Admins can't delete accounts or reset passwords.
- There's no audit log of who changed what.

**Likely questions:**
- *Why not put the admin flag in the JWT?* It's quicker, but a removed admin would keep their rights until the token expires, up to 12 hours.
- *Why lock all the admin rows, not just one?* The two requests touch different rows, so locking only the target wouldn't make them wait for each other.
- *Why can't an admin remove themselves?* It blocks the simplest way to end up with no admins. Another admin can do it instead.

---

## 14. Load test

**What changed:** ran a stepped load test on the live site with k6, and saved the results in `docs/load-test.md`.

**How:** six one-minute steps from 10 to 400 requests a second, using 70% event list, 20% seat map, and 10% booking requests. It used a temporary event and throwaway accounts.

**Result:** 100 requests a second with no failures and a 181 ms 95th percentile. At 200, 3.2% failed. At 400, 73.5% failed.

**The important finding:** the limit was the Cloud Run instance cap, not the database. Failures were `429` responses. The database peaked at about 50% CPU and 18 connections, and 1,732 bookings matched 1,732 booked seats exactly. The connection budget from entry 8 did its job.

**Likely questions:**
- *What's your app's capacity?* About 100 requests a second on this setup, measured for 60 seconds. It's a measured number for a specific traffic mix, not a guarantee.
- *Why did response times hit 10 seconds at 200?* Requests queued waiting for a free instance, and some gave up and got a `429`.
- *How would you go higher?* Use a larger database first, because it sets the connection budget. Then raise the instance limit. Connection pooling, such as PgBouncer, would help too.
- *Isn't failing 73% of requests bad?* At twice the safe load, refusing requests quickly is better than letting the database fall over and losing bookings. It's called load shedding.
- *How do you know nothing was double-booked?* The counts matched exactly, and the database enforces it with a unique index.
- *What wasn't tested?* Long-running load, login, and traffic beyond what one laptop can send.

---

## 15. UI redesign

**What changed:** the site now looks like a theatre: a marquee hero with bulb lights over a red curtain, ticket-shaped event cards, a seat map with rows and an aisle, an order panel, tickets with references, and a redesigned admin page.

**What improved beyond looks:**
- **Links work.** Each page has its own address, like `#/events/2`, so the back button, refresh, and sharing a link all work. This is called hash routing.
- **Phones get their own layout.** The order panel becomes a fixed bar at the bottom of the screen.
- **Better states.** There are loading placeholders, friendly empty pages, retry buttons, and a clear message when the site is busy (`429`).
- **Accessibility.** It works with a keyboard, screen reader labels are included, and animation stops for people who ask for reduced motion.
- **Honest labels.** The footer says it's a portfolio project and no real tickets are sold.

**Still simple on purpose:** there's no framework or build step. It's plain HTML, CSS, and JavaScript served by the API, so it adds nothing to deploy.

**Bug found by looking, not testing:** automated tests passed while the date stub on event cards was the wrong height, because a `button` doesn't stretch its contents. Screenshots caught it. Cards are now real links, which also lets people open them in a new tab.

**Likely questions:**
- *Why no React?* The UI is small, and a framework would add a build step and more to maintain. The project is about delivery, so I kept the frontend simple.
- *How is user input kept safe?* Text is inserted with `textContent`, so an event name can't run as code.
- *Why did you redesign it if this is a DevOps project?* Recruiters open the live link first, and a working, polished site makes them read further.

---

## 16. Private Grafana behind a Wag VPN

**What changed:** Grafana runs privately on a small VM, reachable only through a Wag VPN. A public read-only version was built first and dropped before it ever went live, because metrics don't need to be public. Enrolment steps are in `docs/vpn-access.md`.

**What Wag is:** WireGuard with MFA, device enrolment, and route restrictions. Plain WireGuard stops at "this device has the key". Wag adds "and the person passed MFA".

**How a request gets through:**
1. The laptop connects with WireGuard on UDP port 53230.
2. It can reach the MFA page, but nothing else.
3. After a TOTP code, Wag opens a route to Grafana.
4. Grafana reads metrics from Google Cloud Monitoring using the VM's service account.

**Why a VM:** Cloud Run only serves HTTP requests. A VPN needs a long-running process with root, `iptables`, and a UDP port. This is the project's only always-on server.

**Key decisions:**
- **Only one internet-facing port.** Grafana has no published port. SSH and enrolment use Identity-Aware Proxy (IAP), so the enrolment page is never public.
- **The VPN key is made on the VM,** so it never lands in Terraform state or logs.
- **Wag's admin UI is off,** partly because it prints a password to the logs on startup.
- **Grafana is on a Docker network,** so reaching it passes through Wag's firewall rules.
- **A separate Terraform module,** with a small `e2-micro` VM and 1 GB of swap.

**How it was tested:** a local replica had a Wag server, a private target, and a client. Before MFA the target timed out. After a real TOTP sign-in in a browser it returned 200. Wag's own other ports stayed closed through the tunnel. Enrolment data survived a restart.

**Live check:** a real device enrolled and reached Grafana after TOTP. All 7 panels returned real data, including the load test peak of about 148 requests a second, 18 database connections, and 46% database CPU. From the internet, TCP ports 22, 3000, 8080, 8081, and 4433 were closed. The VM runs at about 660 MB of its 969 MB memory, using some swap.

**Known risks:**
- **Wag 9.1.12, the latest release, has 2 critical scanner findings:** `CVE-2026-114406` in the image's `ca-certificates` package, and `CVE-2026-33186` in the `grpc` library inside Wag. No newer release exists. The risk is reduced because Wag's clustering listens on localhost, and only WireGuard is exposed. Move to a fixed release when one appears.
- **Costs more than Cloud Run.** It's billed all the time, at about ₹900 a month.
- **Single point of failure.** If this VM goes down, you lose the dashboard, but the site stays up.
- **Dashboards load at boot,** so changes need a VM restart.
- **Metrics only.** Logs are still in Cloud Logging.

**Likely questions:**
- *Why not just a Grafana password?* A login page on the internet can be attacked. Behind the VPN there's nothing to attack without a device key and an MFA code.
- *What's the difference between WireGuard and Wag?* WireGuard handles the encrypted tunnel. Wag adds MFA and per-route access rules on top.
- *What's a better option at company scale?* An identity-aware proxy with single sign-on, like Cloudflare Access or Google IAP, so there's no VPN to run.
- *Why did you ship with a critical CVE?* It was a documented decision. There's no fixed version, the affected service isn't exposed, and it's recorded so it gets revisited.
- *What's IAP?* A Google service that checks your identity before forwarding traffic to a private VM, so port 22 needs no public access.
