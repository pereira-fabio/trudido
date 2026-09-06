# Builds the browser app and serves it with nginx.
#
# Built from the repository root, because the Flutter sources are there:
#   docker compose build web
#
# The version floor comes from pubspec.lock; see the Analyze workflow, which
# pins the same one.
FROM ghcr.io/cirruslabs/flutter:3.47.2 AS build

WORKDIR /app

# Dependencies first, so editing Dart does not re-resolve them on every build.
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY lib/ ./lib/
COPY web/ ./web/
COPY assets/ ./assets/
COPY analysis_options.yaml ./

# -t lib/main_web.dart is not optional. The Android entry point reaches about a
# dozen files that import dart:io, which cannot compile for web at all.
RUN flutter build web --release -t lib/main_web.dart

FROM nginx:alpine
COPY --from=build /app/build/web /usr/share/nginx/html
COPY server/web/nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
