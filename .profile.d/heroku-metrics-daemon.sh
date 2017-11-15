#!/bin/bash

# don't do anything if we don't have a metrics url.
if [[ -z "$HEROKU_METRICS_URL" ]] || [[ "${DYNO}" != web\.* ]]; then
    return 0
fi

export HEROKU_METRICS_PROM_ENDPOINT=${HEROKU_METRICS_PROM_ENDPOINT:-/metrics}
export HEROKU_METRICS_PROM_PORT=$((PORT + 1))

STARTTIME=$(date +%s)
BUILD_DIR=/tmp

DOWNLOAD_URL=$(curl --retry 3 -s https://agentmon-releases.s3.amazonaws.com/latest)
if [ -z "${DOWNLOAD_URL}" ]; then
    echo "!!!!! Failed to find latest agentmon. Please report this as a bug. Metrics collection will be disabled this run."
    return 0
fi

BASENAME=$(basename "${DOWNLOAD_URL}")

curl -L --retry 3 -s -o "${BUILD_DIR}/${BASENAME}" "${DOWNLOAD_URL}"

# Ensure the bin folder exists, if not already.
mkdir -p "${BUILD_DIR}/bin"

# Extract agentmon release
tar --warning=no-unknown-keyword -C "${BUILD_DIR}/bin" -zxf "${BUILD_DIR}/${BASENAME}"
chmod +x "${BUILD_DIR}/bin/agentmon"

ELAPSEDTIME=$(($(date +%s) - STARTTIME))
echo "agentmon setup took ${ELAPSEDTIME} seconds"

AGENTMON_FLAGS=()

# heroku-metrics-agent.jar is added in bin/compile
if [[ -f bin/heroku-metrics-agent.jar ]]; then
    if [[ -f build.sbt ]] || # Scala
       [[ -d target/resolution-cache ]]; then # Scala (sbt-heroku)
        unzip -qq bin/heroku-metrics-agent.jar 'javax/*' -d bin/ext/
        export JAVA_OPTS="-javaagent:bin/heroku-metrics-agent.jar=cp=/app/bin/ext/ -Xbootclasspath/a:bin/heroku-metrics-agent.jar ${JAVA_OPTS}"
        AGENTMON_FLAGS+=("-prom-url=http://localhost:${HEROKU_METRICS_PROM_PORT}${HEROKU_METRICS_PROM_ENDPOINT}")
    elif [[ -f pom.xml ]] || # Maven
         [[ -f build.gradle ]] || # Gradle
         [[ -f project.clj ]] || # Clojure
         [[ -f target/dependency/webapp-runner.jar ]] || # Tomcat
         [[ -d .jdk ]]; then # heroku/jvm
        export JAVA_TOOL_OPTIONS="-javaagent:bin/heroku-metrics-agent.jar ${JAVA_TOOL_OPTIONS}"
        AGENTMON_FLAGS+=("-prom-url=http://localhost:${HEROKU_METRICS_PROM_PORT}${HEROKU_METRICS_PROM_ENDPOINT}")
    fi
else
    AGENTMON_FLAGS+=("-statsd-addr=:${PORT}")
fi

if [[ "${AGENTMON_DEBUG}" = "true" ]]; then
    AGENTMON_FLAGS+=("-debug")
fi

if [[ -x "${BUILD_DIR}/bin/agentmon" ]]; then
    (while true; do
        ${BUILD_DIR}/bin/agentmon "${AGENTMON_FLAGS[@]}" "${HEROKU_METRICS_URL}"
        echo "agentmon completed with status=${?}. Restarting"
        sleep 1
    done) &
else
    echo "No agentmon executable found. Not starting."
fi
