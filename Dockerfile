# syntax=docker/dockerfile:1

# ---------- Stage 1: build ----------
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
# Copy only pom.xml first so the dependency layer is cached between builds
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q package -DskipTests

# ---------- Stage 2: runtime ----------
# Distroless: JRE only. No shell, no package manager. Pinned by digest.
FROM gcr.io/distroless/java21-debian12:nonroot@sha256:7e37784d94dccbf5ccb195c73b295f5ad00cd266512dfbac12eb9c3c28f8077d
WORKDIR /app
COPY --from=build /src/target/*.jar /app/app.jar
# Numeric UID so Kubernetes can verify runAsNonRoot (it can't check a user NAME)
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/bin/java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
