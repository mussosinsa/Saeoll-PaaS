ARG BASE_REGISTRY=docker.io/library
FROM ${BASE_REGISTRY}/maven:3.9-eclipse-temurin-17 AS build
# NEXUS_URL (build-arg): dependencies from the company Nexus (cicd-deps.sh); empty: Maven Central
ARG NEXUS_URL
ENV CICD_DEPS_DIR=/tmp/cicd-deps
WORKDIR /src
COPY cicd-deps.sh /tmp/cicd-deps.sh
COPY pom.xml .
RUN . /tmp/cicd-deps.sh && mvn -B -q dependency:go-offline
COPY src ./src
RUN . /tmp/cicd-deps.sh && mvn -B -DskipTests package

FROM ${BASE_REGISTRY}/eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /src/target/app.jar app.jar
RUN useradd -r -u 10001 app
USER 10001
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
