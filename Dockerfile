# syntax=docker/dockerfile:1

# ---------- Stage 1: build ----------
FROM maven:3.9-eclipse-temurin-21@sha256:99e61abcff91a9b1333463bd8451fb18495d6eba9250ac66a338b518f8278320 AS build
WORKDIR /src
# Copy only pom.xml first so the dependency layer is cached between builds
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q package -DskipTests

# ---------- Stage 2: runtime ----------
# Distroless: JRE only. No shell, no package manager. Pinned by digest.
# debian13, not debian12: the debian12 base carries 10 fixable HIGH CVEs
# (libexpat1, liblcms2-2) that would fail the image gate, and distroless has no
# package manager to patch them yourself. debian13 scans clean.
FROM gcr.io/distroless/java21-debian13:nonroot@sha256:a2aeb5a7a714cfe928b31fdf67b2d23f503ea6b9612705af062de22e0c50ba77
WORKDIR /app
COPY --from=build /src/target/*.jar /app/app.jar
# Numeric UID so Kubernetes can verify runAsNonRoot (it can't check a user NAME)
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/bin/java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
