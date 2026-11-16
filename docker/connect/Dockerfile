FROM alpine:3.20 AS fetch
RUN apk add --no-cache curl unzip
ARG JDBC_VERSION=10.7.4
ARG PG_JDBC=42.7.4
RUN curl -fSL -o /tmp/jdbc.zip \
      "https://api.hub.confluent.io/api/plugins/confluentinc/kafka-connect-jdbc/versions/${JDBC_VERSION}/confluentinc-kafka-connect-jdbc-${JDBC_VERSION}.zip" \
 && unzip -q /tmp/jdbc.zip -d /tmp && mv /tmp/confluentinc-kafka-connect-jdbc-* /tmp/jdbc-plugin \
 && curl -fSL -o /tmp/postgresql.jar \
      "https://repo1.maven.org/maven2/org/postgresql/postgresql/${PG_JDBC}/postgresql-${PG_JDBC}.jar"

FROM quay.io/debezium/connect:3.0.0.Final
COPY --from=fetch /tmp/jdbc-plugin/lib/ /kafka/connect/kafka-connect-jdbc/
COPY --from=fetch /tmp/postgresql.jar   /kafka/connect/kafka-connect-jdbc/
