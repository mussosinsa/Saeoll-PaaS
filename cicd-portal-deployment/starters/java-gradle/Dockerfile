ARG BASE_REGISTRY=docker.io/library
FROM ${BASE_REGISTRY}/gradle:8.10-jdk17 AS build
# NEXUS_URL (build-arg): dependencies from the company Nexus (cicd-deps.sh); empty: the public repositories
ARG NEXUS_URL
ENV CICD_DEPS_DIR=/tmp/cicd-deps
WORKDIR /src
COPY . .
RUN . ./cicd-deps.sh && if [ -x ./gradlew ]; then ./gradlew --no-daemon bootJar; else gradle --no-daemon bootJar; fi

FROM ${BASE_REGISTRY}/eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /src/build/libs/*.jar app.jar
RUN useradd -r -u 10001 app
USER 10001
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
