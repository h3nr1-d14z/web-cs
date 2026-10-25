# One-shot job: pull CS 1.6 content through SteamCMD and produce
# /out/game.zip (+ unpacked valve/ and cstrike/ for the game server).
#
# Runs as the image's `steam` user: SteamCMD refuses to work reliably as root.
# /out is created here with that ownership so a fresh named volume inherits it
# (Docker copies mount-point metadata into an empty volume).
FROM cm2network/steamcmd:root

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends zip unzip ca-certificates curl coreutils \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /out \
 && chown -R steam:steam /out

COPY docker/assets.sh /usr/local/bin/assets.sh
COPY config/motd.txt /opt/config/motd.txt
COPY config/liblist.gam /opt/config/liblist.gam
COPY config/resource /opt/config/resource
RUN chmod +x /usr/local/bin/assets.sh

USER steam
ENV HOME=/home/steam
ENV OUT_DIR=/out

VOLUME ["/out"]
ENTRYPOINT ["/usr/local/bin/assets.sh"]
