# Build stage
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline
COPY src ./src
RUN mvn package -DskipTests

# Run stage
FROM eclipse-temurin:17-jre-jammy
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar

# The temurin image has no non-root user; create one with a numeric UID so the pod can
# run under runAsNonRoot.
RUN useradd --uid 1001 --create-home --shell /usr/sbin/nologin appuser
USER 1001

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
