ARG BASE_REGISTRY=docker.io/library
FROM ${BASE_REGISTRY}/maven:3.9-eclipse-temurin-17 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -DskipTests package

FROM ${BASE_REGISTRY}/eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /src/target/app.jar app.jar
RUN useradd -r -u 10001 app
USER 10001
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
