# OBS Studio in LinuxServer's Selkies desktop, reached from a browser.
#
# Built rather than pulled because there is no maintained OBS image to pull:
# LinuxServer publishes none, and what Docker Hub has is single-maintainer and
# years stale. Their base image is maintained, so the app is all this adds.
#
# Ubuntu, not the Debian base, because of where OBS comes from. The OBS
# project's own PPA builds include the browser source that captures
# BambuBoard's /live page; Debian's obs-studio package is built without it,
# and OBS would have no way to show the printer at all.
FROM ghcr.io/linuxserver/baseimage-selkies:ubuntunoble

ENV TITLE="OBS Studio"

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      gpg-agent \
      software-properties-common && \
    add-apt-repository -y ppa:obsproject/obs-studio && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      obs-studio \
      # VAAPI drivers for the iGPU passed in as /dev/dri: Intel, then AMD.
      intel-media-va-driver \
      mesa-va-drivers && \
    apt-get purge -y --auto-remove \
      gpg-agent \
      software-properties-common && \
    rm -rf /var/lib/apt/lists/* /tmp/*

# The base image launches whatever this file names once the desktop is up.
# --disable-shutdown-check: the container is stopped by signal, which OBS
# counts as a crash, and the safe-mode prompt it then opens on every start
# would sit in front of the scene until someone clicks it away.
RUN echo "obs --disable-shutdown-check" > /defaults/autostart
