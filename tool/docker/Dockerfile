# Pinned build environment for analyze, tests and the Android APK.
# Versions come from tool/versions.env (passed as build args by build.sh,
# build.ps1 and CI), so every machine builds with the same toolchain.
ARG JAVA_VERSION=17
FROM eclipse-temurin:${JAVA_VERSION}-jdk-noble

ARG FLUTTER_VERSION
ARG ANDROID_CMDLINE_TOOLS
ARG ANDROID_PLATFORM
ARG ANDROID_BUILD_TOOLS
ARG ANDROID_NDK
ARG ANDROID_CMAKE

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git curl unzip xz-utils zip ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk
ENV PATH=$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH
RUN mkdir -p $ANDROID_HOME/cmdline-tools \
 && curl -fsSL -o /tmp/clt.zip \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS}_latest.zip" \
 && unzip -q /tmp/clt.zip -d /tmp/clt \
 && mv /tmp/clt/cmdline-tools $ANDROID_HOME/cmdline-tools/latest \
 && rm -rf /tmp/clt /tmp/clt.zip \
 && yes | sdkmanager --licenses > /dev/null \
 && sdkmanager \
      "platform-tools" \
      "platforms;${ANDROID_PLATFORM}" \
      "build-tools;${ANDROID_BUILD_TOOLS}" \
      "ndk;${ANDROID_NDK}" \
      "cmake;${ANDROID_CMAKE}" > /dev/null

# Builds may run as the host user (any uid on Linux), so the SDKs, home and
# caches are writable by everyone; Flutter writes into its own SDK folder.
ENV FLUTTER_HOME=/opt/flutter \
    HOME=/home/build \
    PUB_CACHE=/cache/pub \
    GRADLE_USER_HOME=/cache/gradle \
    FLUTTER_SUPPRESS_ANALYTICS=true
ENV PATH=$FLUTTER_HOME/bin:$PUB_CACHE/bin:$PATH
RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" \
      https://github.com/flutter/flutter.git $FLUTTER_HOME \
 && git config --system --add safe.directory '*' \
 && mkdir -p $HOME $PUB_CACHE $GRADLE_USER_HOME /work \
 && flutter config --no-analytics --no-cli-animations > /dev/null \
 && dart --disable-analytics > /dev/null \
 && flutter precache --android --no-ios --no-web --no-linux --no-windows --no-macos \
 && chmod -R a+rwX $FLUTTER_HOME $ANDROID_HOME $HOME /cache /work

WORKDIR /work
