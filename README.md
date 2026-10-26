# Golden Path Starter (Java) – P1

A small Spring Boot service with a **secure-by-default container and CI pipeline**:
the kind of baseline a platform team gives every new service.

![ci](https://github.com/sharsha2/golden-path-java/actions/workflows/ci.yml/badge.svg)

## What it proves

| Control | How | Evidence |
|---|---|---|
| Minimal, non-root image | Multi-stage build, distroless Java 21 (debian13), both stages pinned by digest, UID 65532 | `docs/scan-before.txt` vs `docs/scan-after.txt` |
| No stored cloud secrets | GitHub OIDC tokens verified by a custom verifier (main branch only); GHCR push with the job-scoped `GITHUB_TOKEN` | [`scripts/verify_oidc.py`](scripts/verify_oidc.py), job `oidc-lab` |
| Least-privilege CI | Read-only default token, `id-token: write` / `packages: write` only where needed, every action SHA-pinned | [`.github/workflows/ci.yml`](.github/workflows/ci.yml) |
| Vulnerable dependencies blocked | Trivy `fs` + image gates, fail on fixable HIGH/CRITICAL | PR #&lt;n&gt;: Log4Shell blocked |
| Secrets blocked | Gitleaks on full history (`fetch-depth: 0`) | PR #&lt;n&gt; |
| Workflows audited as code | zizmor on every PR — catches template injection, dangerous triggers, cache poisoning | job `workflow-scan` |
| Supply chain hygiene | Dependabot with a 7-day cooldown, SHA pins, OpenSSF Scorecard &lt;before&gt; → &lt;after&gt; | `.github/dependabot.yml`, `docs/scorecard-*.txt` |

## Run it

```bash
docker build -t golden-path:local . && docker run --rm -p 8080:8080 golden-path:local
curl localhost:8080/api/hello
kubectl apply -k k8s/overlays/dev
```

## Pipeline shape

```
PR:    test ─┐
             ├─ dependency-scan ─┬─ image (build + scan)      → never pushes
             ├─ secret-scan ─────┤
             └─ workflow-scan ───┘
main:  the same, plus oidc-lab, and image pushes to GHCR
```

Three deliberate choices:

- **Scan what you ship.** The image gate runs against the built artifact, not a guess about it.
- **Scan jobs hold no credentials.** Only the final push step on `main` gets `packages: write`. This is the lesson from the March 2026 Trivy and May 2026 TanStack attacks: jobs running third-party code should have nothing worth stealing.
- **`ignore-unfixed: true`** so the gate only fails on things you can actually act on. Unfixable findings are tracked in [`.trivyignore`](.trivyignore) with an owner and a review date, never silenced wholesale.

## What I deliberately did NOT do (yet)

- **Image signing and SBOMs:** next project (P2).
- **Pod security hardening and admission policies:** P4.
- **SAST (CodeQL/Semgrep):** Month 5.

---

# How it was built, stage by stage

What follows is the full lab write-up — every stage, every decision, and a
reference for every terminal command used. The section above is the summary; this
is the detail.

A tiny Spring Boot service used as a hands-on lab for **container and Kubernetes
security**. The app itself is deliberately boring — one endpoint that returns a
greeting. The interesting part is everything around it: how it gets packaged,
how it gets hardened, and how it gets deployed.

The repo is built in five stages: build it, package it two ways (one bad, one
hardened), deploy it, split it per environment, then break it on purpose to
learn how to diagnose and recover. Where there's a bad version
and a good version, both are kept — so you can measure the difference instead of
taking it on faith.

There's also a **[command reference](#command-reference--every-command-used-and-what-it-means)**
near the end explaining every terminal command used, flag by flag.

---

## The application

One HTTP endpoint plus health checks. That's it.

| Endpoint | Returns | Why it exists |
|---|---|---|
| `GET /api/hello` | `{"message":"Hello"}` | Something to prove the app is alive and that config injection works |
| `GET /actuator/health/liveness` | `{"status":"UP"}` | "Is the process healthy?" — Kubernetes restarts the pod if this fails |
| `GET /actuator/health/readiness` | `{"status":"UP"}` | "Can it serve traffic yet?" — Kubernetes withholds traffic until this passes |

The greeting text comes from the `app.greeting` property, which can be
overridden by an environment variable. That one detail is what lets the
Kubernetes stage demonstrate configuration injection.

Key files:

- `src/main/java/dev/lab/goldenpath/HelloController.java` — the endpoint
- `src/main/resources/application.properties` — config, including the actuator allowlist
- `pom.xml` — Spring Boot 4.1.1, Java 21

### A security detail in the config

```properties
management.endpoints.web.exposure.include=health,info
```

Spring Actuator can expose a lot: heap dumps, environment variables, loggers,
thread dumps. Several of those leak secrets or let an attacker change runtime
behaviour. This line is an **allowlist** — only `health` and `info` are
reachable. Everything else stays off. This is the single most commonly
misconfigured thing in a Spring Boot deployment.

---

## Stage 1 — Build and run locally

```sh
./mvnw verify
java -jar target/golden-path-java-0.0.1-SNAPSHOT.jar &
curl -s localhost:8080/api/hello
kill %1
```

> **zsh gotcha:** don't paste trailing `# comments` onto these commands. In an
> interactive zsh, `#` is *not* a comment by default, so the text gets passed
> to the program as arguments and you get confusing errors like
> `Unknown lifecycle phase "#"`. Fix it permanently with:
> `echo 'setopt interactive_comments' >> ~/.zshrc`

---

## Stage 2 — Two Dockerfiles, deliberately different

This is the heart of the lab. The same app is packaged twice.

### `Dockerfile.naive` — how not to do it

```dockerfile
FROM eclipse-temurin:21-jdk    # full JDK, not a JRE
WORKDIR /app
COPY . .                       # copies everything, including junk
RUN ./mvnw -B -q package -DskipTests
CMD ["sh", "-c", "java -jar target/*.jar"]
```

Four problems, all of them common in real projects:

1. **Runs as root.** No `USER` line, so the container's process is root. If
   someone escapes the app, they're root inside the container — and that is the
   starting point for most container escapes.
2. **The build toolchain ships to production.** Maven, the full JDK, a shell, a
   package manager, and the entire `~/.m2` dependency cache all end up in the
   final image. None of it is needed to *run* a jar; all of it is extra attack
   surface.
3. **`COPY . .` copies indiscriminately** — local build output, and anything
   else sitting in the directory. This is how credentials and `.env` files leak
   into images. (`.dockerignore` mitigates it, but the pattern is still wrong.)
4. **Scanning finds leaked passwords** — see below.

### `Dockerfile` — the hardened version

Two stages. The first builds, the second only runs.

```dockerfile
# Stage 1: build (thrown away)
FROM maven:3.9-eclipse-temurin-21 AS build
COPY pom.xml .
RUN mvn -B -q dependency:go-offline   # cached layer: deps change rarely
COPY src ./src
RUN mvn -B -q package -DskipTests

# Stage 2: runtime (this is what ships)
FROM gcr.io/distroless/java21-debian12:nonroot@sha256:7e37784d...
COPY --from=build /src/target/*.jar /app/app.jar
USER 65532:65532
ENTRYPOINT ["/usr/bin/java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
```

What each decision buys you:

- **Multi-stage build** — only the finished jar crosses into stage 2. Maven,
  the compiler, and the dependency cache are left behind in a discarded layer.
- **Distroless base** — a JRE and its libraries, nothing else. No shell, no
  package manager, no `curl`. An attacker who gets code execution has no tools
  to pivot with, and can't `apt-get install` any.
- **`COPY pom.xml` before `COPY src`** — dependencies are downloaded in their
  own layer, which Docker caches. Changing your source code doesn't re-download
  the internet.
- **Pinned by digest (`@sha256:...`)** — not just `:nonroot`. Tags are mutable;
  whoever controls the registry can change what `:nonroot` points to. A digest
  is the image's content hash, so the build is reproducible and can't be swapped
  under you. This is a real supply-chain control.
- **Numeric UID (`65532:65532`), not a name** — Kubernetes enforces
  `runAsNonRoot` by checking the UID. It *cannot* resolve a username like
  `nonroot` into a number, so a name-based `USER` can fail that check. Always
  use digits here.
- **`-XX:MaxRAMPercentage=75`** — tells the JVM to size its heap against the
  *container's* memory limit, leaving headroom for non-heap memory. Without it a
  JVM can get OOM-killed by the kernel while believing it's within budget.

> If you ever see `invalid reference format` with `PASTE_DIGEST_HERE` in the
> message, the digest placeholder was never filled in. Get the real one with:
> `docker buildx imagetools inspect gcr.io/distroless/java21-debian12:nonroot`
> and use the **top-level index digest** so the build still works on both arm64
> and amd64.

### Measuring the difference

```sh
docker build -f Dockerfile.naive -t golden-path:naive .
docker build -t golden-path:0.1.0 .

trivy image --severity HIGH,CRITICAL --quiet golden-path:naive  | tee docs/scan-before.txt
trivy image --severity HIGH,CRITICAL --quiet golden-path:0.1.0  | tee docs/scan-after.txt

docker image ls golden-path --format '{{.Tag}}  {{.Size}}'
docker inspect golden-path:0.1.0 --format 'User: "{{.Config.User}}"'
docker run --rm --entrypoint sh golden-path:0.1.0 || echo "No shell inside - good"
```

Results, saved in `docs/`:

| | naive | hardened (0.1.0) |
|---|---|---|
| Image size | 623 MB | **224 MB** |
| Runs as | root (`""`) | **`65532:65532`** |
| Shell available | yes | **no** |
| Leaked secrets found | **3** | **0** |

The 3 secrets in the naive image are hardcoded passwords in Maven's bundled
`conf/settings.xml` (`proxyuser`, `repouser`). They're only there because the
build toolchain shipped to production — exactly the thing multi-stage fixes.

### Be honest about the scan numbers

**OS CVEs went up, from 0 to 16 — and this was later fixed by changing base image.**
Worth understanding, because the first attempt looked like a regression:

- The naive image is based on Ubuntu 26.04, which currently has 0 known
  HIGH/CRITICAL CVEs in its installed packages.
- The distroless image is based on Debian 12, which has 15 HIGH + 1 CRITICAL
  across `libexpat1`, `libuuid1`, `liblcms2-2`, and `zlib1g`. The `zlib1g`
  CRITICAL is marked `will_not_fix` upstream.

So **"distroless" does not mean "no CVEs."** It means a far smaller attack
surface, no shell, and no tools for an attacker to use. Those are different
properties from a CVE count, and a scanner only measures the latter.

**Resolution:** when Stage 6 added a Trivy image gate, those 10 *fixable* HIGH
findings would have failed the build — and distroless has no package manager, so
you cannot patch them yourself. Switching the base to
`gcr.io/distroless/java21-debian13:nonroot` scans **completely clean (0
findings)**, so the Dockerfile now pins debian13. The lesson: when a base image
lags on security updates, the fix is to change base image, not to add
exceptions.

**Also unchanged: 8 CVEs in the application's own dependencies** — 3 CRITICAL in
`tomcat-embed-core` 11.0.24 (authentication and security-constraint bypasses)
and 5 HIGH in `jackson-core` / `jackson-databind` 3.1.5. No Dockerfile change
can fix these; they need a dependency upgrade. **For a service actually exposed
to traffic, these matter more than any of the OS findings above.**

---

## Stage 3 — Deploy to Kubernetes

### Set up a throwaway cluster

```sh
kind create cluster --name lab
kubectl cluster-info --context kind-lab
kubectl get pods -A                      # all system pods should be Running
```

`kind` runs Kubernetes nodes as Docker containers. It's disposable — break it
and run `kind delete cluster --name lab`.

### Load the image (do not skip this)

```sh
docker build -t golden-path:0.1.0 .
kind load docker-image golden-path:0.1.0 --name lab
```

**A kind cluster cannot see your local Docker images.** It has its own
container runtime. Without `kind load`, the pod tries to pull `golden-path:0.1.0`
from Docker Hub, fails, and you get `ErrImagePull` / `pull access denied`. That
error message sounds like an auth problem but actually means "this image isn't
here and isn't public."

### What's in `k8s/base/`

Three files, applied together with Kustomize.

**`deployment.yaml`** — how to run the container:

- **`image: golden-path:0.1.0` + `imagePullPolicy: IfNotPresent`** — use the
  locally loaded image, don't try the registry.
- **Config from a ConfigMap** — `APP_GREETING` is injected as an env var.
  Spring relaxed binding maps `APP_GREETING` onto the `app.greeting` property
  automatically, so the same image behaves differently per environment without
  a rebuild. **This is why the app reads its greeting from config.**
- **A fake secret from a Secret** — `DB_PASSWORD` shows the injection
  *mechanism*. The app never reads it; it's there to demonstrate the wiring.
- **Resource requests and limits:**
  ```yaml
  requests: { cpu: 100m, memory: 256Mi }
  limits:   { memory: 512Mi }           # note: no CPU limit
  ```
  `requests` is what the scheduler reserves; `limits` is the hard ceiling.
  **Memory has a limit but CPU deliberately does not** — exceeding a memory
  limit gets the container OOM-killed, so a ceiling protects the node, whereas a
  CPU limit causes *throttling*, which on the JVM shows up as mysterious latency
  spikes and slow startup. Reserve CPU, cap memory.
- **Three probes, each with a different job:**

  | Probe | Asks | On failure |
  |---|---|---|
  | `startupProbe` | "has it finished booting?" | keeps waiting (up to 60s here) |
  | `livenessProbe` | "is it still healthy?" | restarts the pod |
  | `readinessProbe` | "can it take traffic?" | removes it from the Service |

  The `startupProbe` matters for the JVM specifically. Without it you'd need a
  long `initialDelaySeconds` on the liveness probe, and a slow start would get
  the pod killed in a restart loop before it ever came up.

**`service.yaml`** — a stable address. Pods come and go with changing IPs; the
Service gives one name that load-balances to whatever matches the label
selector. Here `port: 80` (what clients call) maps to `targetPort: http`, the
*named* port from the Deployment — so if the container port ever changes, the
name still resolves and nothing breaks.

**`kustomization.yaml`** — ties it together and generates the ConfigMap and
Secret from literals. Kustomize appends a **content hash** to their names:

```
golden-path-config  →  golden-path-config-kd4fm6d4mc
```

and rewrites the Deployment's references to match. This is a genuinely useful
trick: change a config value and the hash changes, which changes the Deployment,
which **triggers a rolling restart automatically**. Edit a ConfigMap by hand and
your pods keep running with the old values until something restarts them.

### Deploy and verify

```sh
kubectl apply -k k8s/base
kubectl rollout status deploy/golden-path
kubectl get pods -l app.kubernetes.io/name=golden-path

kubectl port-forward svc/golden-path 18080:80 &
curl -s localhost:18080/api/hello                       # {"message":"Hello from base"}
curl -s localhost:18080/actuator/health/readiness        # {"status":"UP"}
kill %1
```

Confirmed working: the pod reaches `1/1 Running`, and the greeting comes back as
**`Hello from base`** — not the `Hello` baked into the jar. That difference is
the proof that ConfigMap injection is actually taking effect.

```sh
kubectl exec <pod> -- id
# error: "id": executable file not found in $PATH
```

That failure is **the distroless hardening working as intended**. There are no
binaries to run, so there's no interactive debugging — and equally, nothing for
an attacker to use. The tradeoff is real: you debug through logs, metrics, and
ephemeral debug containers (`kubectl debug`) instead of shelling in.

To confirm the UID without a shell, ask the runtime:

```sh
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].containerID}'
docker exec lab-control-plane crictl inspect <id> | grep uid
# "uid": 65532
```

---

## Stage 4 — Environments with Kustomize overlays

Stage 3 deployed `k8s/base` directly. But a real service runs in several
environments that differ in small ways — namespace, replica count, config
values, resource sizing. You do **not** want a copy of the YAML per
environment; they drift and nobody notices.

Kustomize solves this with a **base + overlays** model: one shared definition
plus a small patch per environment.

```
k8s/
├── base/              the shared, environment-agnostic definition
└── overlays/
    └── dev/           only what makes dev different
```

### What's in `k8s/overlays/dev/`

Two small files. Note how little there is — that's the point.

**`namespace.yaml`** — declares the namespace to deploy into:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: golden-path-dev
```

A namespace is a logical partition of the cluster. It gives you a boundary for
names (two environments can both have a Service called `golden-path`), and more
importantly a boundary for **RBAC, quotas, and NetworkPolicy**. Putting each
environment in its own namespace is the groundwork for restricting them later.

**`kustomization.yaml`** — the actual patch:

```yaml
namespace: golden-path-dev          # 1. force everything into this namespace
resources:
  - namespace.yaml
  - ../../base                      # 2. inherit the whole base
configMapGenerator:
  - name: golden-path-config
    behavior: merge                 # 3. patch the base ConfigMap, don't replace it
    literals:
      - APP_GREETING=Hello from DEV
```

Three things worth understanding:

1. **`namespace: golden-path-dev`** — Kustomize stamps this onto *every*
   resource it renders. You don't annotate each file, and you can't forget one.
2. **`resources: ../../base`** — the overlay pulls in the base by path. The base
   is never edited or copied; it's included. Fix a probe in the base and every
   environment inherits the fix.
3. **`behavior: merge`** — this is the key flag. The options are:

   | `behavior` | Effect |
   |---|---|
   | `merge` | keep the base's keys, override only the ones you list |
   | `replace` | throw away the base's keys entirely |
   | `create` | make a new ConfigMap (error if it already exists) |

   With `merge`, dev overrides `APP_GREETING` and inherits every other key the
   base might add later. With `replace`, adding a key to the base would silently
   **not** reach dev — a classic way to get a config bug that only appears in
   one environment.

### Render before you apply

```sh
kubectl kustomize k8s/overlays/dev
```

This prints the final YAML **without touching the cluster**. Get in the habit of
running it first — it's how you confirm a patch did what you meant. Comparing
base against dev shows exactly what the overlay changed:

| | base | dev overlay |
|---|---|---|
| Namespace | *(none — lands in `default`)* | `golden-path-dev` |
| `APP_GREETING` | `Hello from base` | `Hello from DEV` |
| ConfigMap name | `golden-path-config-kd4fm6d4mc` | `golden-path-config-62fh57569h` |
| Secret name | `golden-path-secret-c76g2f2mdd` | `golden-path-secret-c76g2f2mdd` |
| Image, probes, resources | — | **unchanged, inherited** |

Look closely at the last two rows, because they demonstrate something useful:

- The **ConfigMap hash changed** (`kd4fm6d4mc` → `62fh57569h`) because its
  contents changed.
- The **Secret hash is identical** (`c76g2f2mdd`) because the overlay didn't
  touch it.

The hash is a content hash, so **only the things you actually changed trigger a
rolling restart.** Editing the dev greeting restarts the pod; the Secret, being
byte-identical, doesn't force anything.

### Deploy dev

```sh
kubectl apply -k k8s/overlays/dev
kubectl get pods -A
kubectl -n golden-path-dev rollout status deploy/golden-path
kubectl -n golden-path-dev get pods,svc

kubectl -n golden-path-dev port-forward svc/golden-path 8080:80 &
curl -s localhost:8080/api/hello        # {"message":"Hello from DEV"}
kill %1
```

Confirmed working: the pod runs `1/1` in `golden-path-dev`, the Service gets a
ClusterIP, and the greeting comes back **`Hello from DEV`**.

That string is the whole proof of the exercise. The jar has `Hello` compiled
into it. The base overlay says `Hello from base`. Dev says `Hello from DEV`.
**Same image, three different behaviours, zero rebuilds.** That is what
separates configuration from code, and it's why the twelve-factor rule says
config lives in the environment.

### Adding a second environment: `k8s/overlays/prod/`

Prod is the same shape as dev, plus one new idea:

```yaml
namespace: golden-path-prod
resources:
  - namespace.yaml
  - ../../base
replicas:                    # <- new
  - name: golden-path
    count: 3
configMapGenerator:
  - name: golden-path-config
    behavior: merge
    literals:
      - APP_GREETING=Hello from PROD
```

**`replicas:`** is a built-in Kustomize *transformer*, not a hand-written patch.
You name a Deployment and a count, and Kustomize rewrites `spec.replicas` for
you. That matters because replica count is exactly the kind of thing that
differs per environment and that you don't want to express as a fragile YAML
patch. Dev stays at the base's 1; prod gets 3.

Three replicas isn't arbitrary: it means the Deployment can lose a pod (or drain
a node) and still serve traffic, and it lets a rolling update replace pods one at
a time without ever dropping to zero.

### Diffing two environments

This is the single most useful Kustomize habit:

```sh
diff <(kubectl kustomize k8s/overlays/dev) <(kubectl kustomize k8s/overlays/prod)
```

`<(...)` is **process substitution** — the shell runs each command and hands its
output to `diff` as if it were a file. Nothing is written to disk and nothing
touches the cluster.

The real output showed exactly five differences, which is the ideal result:

```diff
-  name: golden-path-dev              →  golden-path-prod        (namespace)
-  APP_GREETING: Hello from DEV       →  Hello from PROD         (config value)
-  name: golden-path-config-62fh57569h → golden-path-config-k9cfh567kf  (hash)
-  replicas: 1                        →  replicas: 3             (scale)
```

Everything else — image, probes, resource requests and limits, the Service, the
Secret — is byte-identical. **That's the proof the overlays aren't drifting.**
If this diff ever grows surprising entries, an overlay has started
reimplementing the base instead of patching it.

Note again that the **Secret hash is the same in both** (`c76g2f2mdd`) while the
**ConfigMap hash differs**. Only the generator you actually overrode changes.

### Deploy prod alongside dev

```sh
kubectl apply -k k8s/overlays/prod
kubectl -n golden-path-prod get pods
```

Verified: 3 pods `1/1 Running` in `golden-path-prod`, while dev's single pod
keeps running untouched in `golden-path-dev`. Two environments, two namespaces,
one base, one image.

---

## Stage 5 — Troubleshooting, drift, and self-healing

Deploying is the easy part. This stage is about what you do when something is
wrong, and what happens when the cluster stops matching Git.

Set a variable first so you're not retyping the namespace:

```sh
NS=golden-path-dev
kubectl -n $NS get pods
```

### The debugging order

There's a fixed sequence, captured in [`docs/kubectl-cheatsheet.md`](docs/kubectl-cheatsheet.md):

```
get  →  describe (read Events)  →  logs (--previous)  →  get events  →  exec
```

| Command | What it tells you |
|---|---|
| `kubectl -n $NS get pods` | The `STATUS` column, which names the failure class |
| `kubectl -n $NS describe pod -l app.kubernetes.io/name=golden-path` | **The Events at the bottom** — scheduling, image pulls, probe failures. The highest-value output in all of kubectl |
| `kubectl -n $NS logs deploy/golden-path` | What the app itself said |
| `kubectl -n $NS logs deploy/golden-path --previous` | Logs from the **crashed** container, before it restarted. Essential for `CrashLoopBackOff`, because the running container is a fresh one with no history |
| `kubectl -n $NS get events --sort-by=.lastTimestamp` | Namespace-wide timeline. Sorting matters — unsorted event output is near-useless |

The cheat sheet maps each `STATUS` to its usual cause: `ImagePullBackOff` →
wrong tag or registry auth; `CrashLoopBackOff` → app crash or bad config;
`CreateContainerConfigError` → a missing ConfigMap/Secret key; `Running` but
`0/1 Ready` → probe path or port wrong; `Pending` → nothing can schedule it;
`OOMKilled` → memory limit too low, or a JVM heap that isn't container-aware.

### Four commands that failed, and why

These are worth keeping, because each failure teaches something real.

**1. `kubectl debug --target golden-path` → `targetContainerName: Not found`**

```
The Pod "golden-path-56ccbb7679-8985d" is invalid:
spec.ephemeralContainers[0].targetContainerName: Not found: "golden-path"
```

`--target` takes the **container** name, not the pod or app name. In
[`k8s/base/deployment.yaml`](k8s/base/deployment.yaml) the container is called
`app`:

```yaml
containers:
  - name: app          # <- this is what --target needs
```

So the working form is:

```sh
kubectl -n $NS debug -it <pod> --image=busybox --target=app
```

Check the name with
`kubectl -n $NS get pod <pod> -o jsonpath='{.spec.containers[*].name}'`.
This command matters more than usual here: because the image is distroless,
`kubectl debug` is the *only* way to get a shell near the app.

**2. `... | tail -25   # Events at the bottom` → `tail: #: No such file or directory`**

The zsh comment trap again, for the third time in this lab. `#` isn't a comment
in interactive zsh, so `tail` received `#`, `Events`, `at`, `the`, `bottom` as
**filenames**. Fix it permanently:

```sh
echo 'setopt interactive_comments' >> ~/.zshrc
```

**3. `logs --previous` → `previous terminated container "app" ... not found`**

This isn't a broken command — it's the correct answer. `--previous` only works
if a container has actually died and been replaced. Nothing had crashed, so
there was no previous container to show. **Seeing this error is good news.**

(The first attempt also failed with `POD or TYPE/NAME is a required argument`,
because the trailing `# logs of the crashed container` comment consumed the
argument — the same `#` problem.)

**4. `kubectl get secret <name-from-above>` → `no such file or directory`**

The placeholder was pasted literally. In zsh, `<name>` is **redirection
syntax**, so the shell tried to read a file called `name-from-above`. Substitute
the real value, or better, avoid the copy step entirely:

```sh
SECRET=$(kubectl -n $NS get secret -o name | grep golden-path-secret)
kubectl -n $NS get $SECRET -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo
# not-a-real-password
```

**That output is the security lesson.** Any value in a Kubernetes Secret can be
read back in plain text by anyone with `get secret` permission —
`base64` is encoding, not encryption. Secrets are *not* secret by default; they
need encryption at rest, RBAC that actually restricts `get secret`, and ideally
an external secret manager.

### The drift experiment

This is the most instructive thing in the stage. Deliberately break the
deployment by pointing it at an image tag that doesn't exist:

```sh
kubectl -n $NS set image deploy/golden-path app=golden-path:9.9.9
kubectl -n $NS get pods
```

`set image` is an **imperative** change — it edits the live cluster directly,
bypassing Git entirely. This is how real drift happens: someone fixes something
by hand at 2am and never tells anyone.

The result is the interesting part:

```
NAME                           READY   STATUS    RESTARTS   AGE
golden-path-56ccbb7679-8985d   1/1     Running   0          12m
```

**The app never went down.** A rolling update creates the new pod *before*
removing the old one. The new pod couldn't pull `9.9.9`, so it never became
Ready, so the old pod was never terminated. Kubernetes refused to complete a
rollout into a broken state. Two correct behaviours in your Deployment made that
work: the `readinessProbe` (nothing joins the Service until it's healthy) and the
default rolling-update strategy.

You can see both ReplicaSets side by side:

```sh
kubectl -n $NS get rs
# golden-path-556fccb879   0   0   0    # the broken 9.9.9 attempt, scaled to zero
# golden-path-56ccbb7679   1   1   1    # the original, still serving
```

### Self-healing: re-apply the desired state

```sh
kubectl apply -k k8s/overlays/dev
```

```
deployment.apps/golden-path configured     <- the only thing that changed
configmap/... unchanged
secret/... unchanged
service/... unchanged
namespace/... unchanged
```

The drift is gone and the image is back to `0.1.0`. Note the output: everything
already matching says `unchanged`, and only the drifted Deployment says
`configured`. `apply` is **declarative** — it reconciles toward the file rather
than issuing a change, which is why running it repeatedly is safe and why it's
the foundation of GitOps.

Verified afterwards: the dev pod is still `56ccbb7679-8985d` with `0` restarts
and its original age. **The bad rollout caused zero downtime and zero restarts.**

### Rolling back

The failed ReplicaSet is kept, not deleted, which is what makes rollback
instant:

```sh
kubectl -n $NS rollout history deploy/golden-path   # revisions 2, 3
kubectl -n $NS rollout undo deploy/golden-path      # back one revision
```

`rollout undo` is the right tool during an incident — it's fast and needs no
Git access. But it reintroduces drift: the cluster now disagrees with your repo.
**Roll back to stop the bleeding, then fix the manifests so `apply` agrees.**

---

## Known gaps / what's next

Honest list of what this repo does *not* yet do:

1. **No `securityContext` in the Deployment.** The image is hardened, but
   Kubernetes isn't being told to enforce it. The pod happens to run as 65532
   because the *image* says so — nothing would stop a future image change from
   running as root. The manifest should assert it:
   ```yaml
   securityContext:
     runAsNonRoot: true
     runAsUser: 65532
     allowPrivilegeEscalation: false
     readOnlyRootFilesystem: true
     capabilities: { drop: ["ALL"] }
   ```
   Defence in depth: the image declares intent, the cluster enforces it. The
   neither overlay adds it, so **no environment currently enforces non-root** —
   not even prod.
2. **8 CVEs in app dependencies** (Tomcat, Jackson) — needs a Spring Boot bump.
3. **Prod isn't meaningfully different from dev.** `k8s/overlays/prod/` sets
   `replicas: 3` and a greeting, but a real prod overlay would also raise
   resource requests, add a PodDisruptionBudget, set anti-affinity so replicas
   land on different nodes, and enforce the `securityContext` above. Right now
   "prod" is dev with more pods.
4. **No NetworkPolicy.** By default every pod can talk to every other pod.
5. **No Pod Security Admission / admission control** to reject root containers
   at the cluster level.
6. **The Secret is only base64-encoded, not encrypted.** Kubernetes Secrets are
   not secret at rest by default — anyone with API read access can decode them.

---

## Command reference — every command used, and what it means

Grouped by tool. Read the "why" column; the commands are easy to copy and hard
to understand.

### Maven (build the Java app)

| Command | What it means |
|---|---|
| `./mvnw` | The **Maven wrapper** — a script that downloads the exact Maven version this project expects. Using `./mvnw` instead of a system `mvn` means everyone builds with identical tooling. |
| `./mvnw verify` | Compile, run tests, package the jar, run any checks. `verify` is the last phase before installing, so it's the "is this good?" command. |
| `-q` | Quiet. Suppresses Maven's INFO chatter so you only see warnings, errors, and test output. |
| `-B` | Batch mode. No ANSI colours, never prompts for input — correct inside Docker builds and CI, where there's no human to answer. |
| `-DskipTests` | Skip tests. Used **in the Dockerfile only**, because tests already ran in `./mvnw verify` on your machine. Don't use this as a habit locally. |
| `mvn dependency:go-offline` | Pre-download every dependency. Its only purpose is to create a cacheable Docker layer so later builds don't re-download the internet. |
| `mvn package` | Compile and produce the jar in `target/`. Stops short of `verify`. |

### Running the jar

| Command | What it means |
|---|---|
| `java -jar target/*.jar` | Run the packaged app. Spring Boot produces a "fat jar" with every dependency inside, so no classpath wrangling. |
| `-XX:MaxRAMPercentage=75` | Size the JVM heap at 75% of **the container's** memory limit rather than the host's RAM. Essential in Kubernetes; the remaining 25% covers non-heap memory (metaspace, threads, native buffers). |
| `java -jar ... &` | The `&` runs it in the background so you get your prompt back. |
| `kill %1` | Kill background job 1 — the thing you just started with `&`. `%1` is a *job* number, not a process ID. |

### Shell / zsh

| Command | What it means |
|---|---|
| `curl -s <url>` | Fetch a URL. `-s` is silent: no progress meter, so the response is clean enough to read or pipe. |
| `-f` | Fail silently on HTTP errors, returning a non-zero exit code. Makes `curl` usable in `if` tests and wait loops. |
| `\| tee file.txt` | Print to the screen **and** write to a file at the same time. Used so the trivy scans are both visible and saved to `docs/`. |
| `mkdir -p docs` | Create the directory, and don't error if it already exists. The `-p` is what makes it safe to re-run. |
| `setopt interactive_comments` | **Fixes a real trap in this lab.** By default, interactive zsh does *not* treat `#` as a comment, so a pasted trailing comment becomes program arguments. This is what produced `Unknown lifecycle phase "#"` and `error: no such object: #`. |
| `NS=golden-path-dev` then `-n $NS` | A shell variable so you stop retyping the namespace — and stop accidentally operating on the wrong one. |
| `diff <(cmd1) <(cmd2)` | **Process substitution.** The shell runs each command and feeds its output to `diff` as a pseudo-file. Nothing hits disk. This is how you compare two rendered overlays. |
| `base64 -d` | Decode base64. Kubernetes stores Secret values this way, so this is all it takes to read one. |
| `cmd \| tail -25` | Show the last 25 lines — used to jump straight to the **Events** block at the bottom of `describe` output. |
| `<name>` pasted literally | **Not a placeholder to zsh** — `<` is input redirection, so you get `no such file or directory`. Substitute the real value or capture it into a variable. |

### Docker (build and inspect images)

| Command | What it means |
|---|---|
| `docker build -t name:tag .` | Build an image from the `Dockerfile` in `.` and label it. The `.` is the **build context** — the files sent to the builder, filtered by `.dockerignore`. |
| `-f Dockerfile.naive` | Use a specific Dockerfile instead of the default `Dockerfile`. How both versions coexist in one repo. |
| `docker run --rm -d -p 8080:8080 --name gp img` | Run a container. `--rm` deletes it on exit (no clutter), `-d` detaches, `-p host:container` maps the port, `--name` gives it a handle. |
| `docker run --rm --entrypoint sh img` | Override the entrypoint to try to get a shell. **Used here as a security test** — on the hardened image it fails, which is the desired result. |
| `docker image ls name --format '...'` | List images with a Go template, so you get just the columns you want (used for the size comparison). |
| `docker inspect img --format 'User: "{{.Config.User}}"'` | Read image metadata. An **empty** user means the container runs as **root** — the single most important thing to check about an image. |
| `docker exec <container> <cmd>` | Run a command inside a *running* container. Used to look inside the kind node. |
| `docker context ls` | Show which Docker daemon the CLI talks to. **Critical on this machine**, which has both Docker Desktop and OrbStack; the starred row is active. |
| `docker buildx imagetools inspect <image>` | Inspect an image in a registry *without pulling it*. How you get the real `sha256:` digest to pin. |
| `--platform linux/arm64 --provenance=false` | Build for one architecture and skip attestation metadata. Produces a plain single-arch image, which avoids `kind load` problems with manifest lists. |

### Trivy (vulnerability and secret scanning)

| Command | What it means |
|---|---|
| `trivy image <image>` | Scan an image: OS packages, application dependencies, and hardcoded secrets. |
| `--severity HIGH,CRITICAL` | Report only what's worth acting on. Without it you drown in LOW/MEDIUM noise. |
| `--quiet` | Suppress progress bars and DB-update chatter, so the piped output is clean. |

Reading the results:

- **`Status: fixed`** — a patched version exists. Upgrade and the finding goes away. These are the actionable ones.
- **`Status: affected`** — vulnerable, with no fix released yet.
- **`Status: will_not_fix`** — upstream has decided not to patch it. Your options are accept the risk, change base image, or remove the package.

### kind (local Kubernetes)

| Command | What it means |
|---|---|
| `kind create cluster --name lab` | Create a cluster whose **nodes are Docker containers**. Fast and completely disposable. |
| `kind delete cluster --name lab` | Destroy it. The whole point of kind: break things freely, then reset. |
| `kind get clusters` | List clusters. Useful because it's easy to accumulate several and forget. |
| `kind load docker-image img --name lab` | **Copy a local image into the cluster's own runtime.** Skip this and you get `ErrImagePull` / `pull access denied`, because the cluster has a *separate* image store and will try Docker Hub instead. |

### kubectl — inspecting

| Command | What it means |
|---|---|
| `kubectl version` | Client and server versions. If the server line answers, you're talking to a live cluster — but check *which* one. |
| `kubectl config current-context` | **Which cluster am I about to change?** Run this before anything destructive. This repo's machine has three contexts. |
| `kubectl config get-contexts` | List every cluster kubectl knows about. |
| `kubectl cluster-info` | Control-plane and CoreDNS endpoints — a quick "is the cluster answering?" |
| `kubectl get nodes` | List nodes and their `Ready` status. |
| `kubectl get pods -A` | Pods in **all** namespaces (`-A` = `--all-namespaces`). Without it you only see the current namespace, which is the usual reason a pod seems "missing". Note: `-a` is **not** valid and errors — it's `-A`. |
| `kubectl -n <ns> get pods,svc` | Query several resource types at once, scoped to a namespace. `-n` is required for anything outside `default`. |
| `kubectl get pods -l key=value` | Filter by **label**. Labels are how Kubernetes groups things; a Service finds its pods the same way. |
| `kubectl get pod <p> -o wide` | Extra columns — pod IP and which node it landed on. |
| `kubectl get ... -o jsonpath='{...}'` | Extract one exact field for scripting, instead of eyeballing YAML. |
| `kubectl describe pod <p>` | Full detail plus the **event log** — the first place to look when a pod won't start. |
| `kubectl logs <p>` | The container's stdout/stderr. With distroless images this is your primary debugging tool, since you can't shell in. |

### kubectl — applying and operating

| Command | What it means |
|---|---|
| `kubectl kustomize <dir>` | Render the final YAML and print it. **Touches nothing.** Always do this before applying a new overlay. |
| `kubectl apply -k <dir>` | Build the kustomization *and* apply it. The `-k` is what makes it Kustomize-aware rather than a plain file apply. |
| `kubectl delete -k <dir>` | Remove everything that kustomization created. Clean teardown. |
| `kubectl apply -f <file>` | Apply plain YAML, no Kustomize. |
| `kubectl rollout status deploy/<name>` | **Block until the rollout finishes or fails.** This is how you turn a deploy into something scriptable instead of polling `get pods` by hand. |
| `kubectl rollout restart deploy/<name>` | Force new pods without changing the spec — e.g. to pick up a hand-edited ConfigMap. |
| `kubectl port-forward svc/<name> 8080:80 &` | Tunnel a local port to a Service inside the cluster. The format is `local:remote`. Lets you `curl` a `ClusterIP` Service that has no external address. |
| `kubectl exec <pod> -- <cmd>` | Run a command inside a pod. **Fails on distroless** — there are no binaries. That failure is the hardening working. |
| `kubectl debug -it <pod> --image=busybox --target=app` | Attach a temporary container with real tools to a running pod — the supported way to debug distroless images. `--target` is the **container** name (`app` here), not the pod or app name. |
| `kubectl set image deploy/<d> <container>=<image>` | Imperatively change the image on the live cluster. Useful for experiments; **this is also how drift happens**, since it bypasses your manifests. |
| `kubectl rollout history deploy/<d>` | List revisions. Old ReplicaSets are retained, which is what makes rollback instant. |
| `kubectl rollout undo deploy/<d>` | Roll back one revision. Fast during an incident, but it reintroduces drift from Git. |
| `kubectl get rs` | List ReplicaSets. Shows a failed rollout scaled to `0` next to the healthy one still serving. |
| `kubectl get events --sort-by=.lastTimestamp` | Namespace-wide event timeline. **Always sort** — unsorted event output is effectively unreadable. |
| `kubectl logs deploy/<d> --previous` | Logs from the **crashed** container, not the running replacement. The key command for `CrashLoopBackOff`. Errors if nothing has crashed — which is good news. |
| `kubectl get secret <s> -o jsonpath='{.data.KEY}' \| base64 -d` | Decode a Secret value. **A security lesson, not a trick:** anyone with `get secret` reads plaintext. base64 is encoding, not encryption. |

### Git

| Command | What it means |
|---|---|
| `git status --short` | Compact view: `M` = modified, `??` = untracked. |
| `git checkout <file>` | Discard local changes to a file and restore it from the last commit. |
| `git log --oneline` | One line per commit — quick history. |
| `git ls-files` | Everything Git is actually tracking. Good for spotting files you meant to commit but didn't. |

---

## Environment notes

Things that caused confusion on this machine and may again:

- **Two container runtimes installed** — Docker Desktop and OrbStack. Check
  which one `docker` talks to with `docker context ls`; the starred row wins.
  `kind load` pushes from the *active* daemon, so switching contexts mid-lab
  puts the image somewhere the cluster can't see it.
- **Three kubectl contexts** — `kind-lab`, `kind-p1`, and `orbstack`. OrbStack
  ships its own Kubernetes, which is *not* the kind cluster. Always confirm with
  `kubectl config current-context` before debugging a "missing" deployment.
- **`java.version` is 21** in `pom.xml`, matching both the Temurin 21 builder
  and the distroless `java21` runtime. Bumping one without the others produces
  `release version N not supported`.
- **Multi-arch builds** produce a manifest list plus attestations, which can
  trip up `kind load`. If it fails, build single-platform:
  `docker build --platform linux/arm64 --provenance=false -t golden-path:0.1.0 .`

## Layout

```
├── src/                     Spring Boot app (one endpoint + health)
├── pom.xml                  Spring Boot 4.1.1, Java 21
├── Dockerfile.naive         the insecure version, for comparison
├── Dockerfile               multi-stage, distroless, non-root, digest-pinned
├── .dockerignore            keeps target/, .git/, .env out of the build context
├── k8s/
│   ├── base/                shared, environment-agnostic definition
│   │   ├── deployment.yaml      container spec, probes, resources, config injection
│   │   ├── service.yaml         stable in-cluster address
│   │   └── kustomization.yaml   ConfigMap + Secret generators with hash suffixes
│   └── overlays/
│       ├── dev/             only what makes dev different
│       │   ├── namespace.yaml      the golden-path-dev namespace
│       │   └── kustomization.yaml  namespace + merged APP_GREETING
│       └── prod/            same, plus replicas: 3
│           ├── namespace.yaml
│           └── kustomization.yaml
└── docs/
    ├── scan-before.txt         trivy output for the naive image
    ├── scan-after.txt          trivy output for the hardened image
    └── kubectl-cheatsheet.md   STATUS → cause → first command, for triage
```
