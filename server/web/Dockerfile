# Serves a prebuilt browser app. Deliberately does not build it.
#
# Compiling Flutter needs several gigabytes of disk and a ~1.5 GB SDK, which is
# a lot to ask of a NAS or an LXC container in order to produce a few megabytes
# of static files. The build happens in CI, or on a machine that already has
# Flutter; this image only serves the result.
#
# Put the build output in ./web-build (see docs/selfhosting.md), then:
#   docker compose up -d --build
FROM nginx:alpine

COPY web-build/ /usr/share/nginx/html/
COPY server/web/nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
