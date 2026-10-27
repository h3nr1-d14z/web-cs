# GoldSrc dedicated server.
#
# ReGameDLL (the CS 1.6 server library we ship) is built for 32-bit Linux only,
# so this image is i386. On an amd64 host the container runs natively through
# the kernel's ia32 compatibility layer — no emulation, no performance hit.
FROM i386/debian:bookworm-slim

ARG XASH_TAG=continuous
ARG REGAMEDLL_VERSION=5.30.0.814
# Tag `continuous` là rolling: tên asset chứa version nên đổi mỗi release —
# build 404 ở bước YaPB thì bump số này theo asset mới nhất.
# Nên bám tag version thật (asset của tag đó không bị thay): 4.4.957 là bản
# stable mới nhất. Muốn bản mới hơn thì `--build-arg YAPB_TAG=continuous
# --build-arg YAPB_VERSION=<số trong tên asset>`.
ARG YAPB_TAG=4.4.957
ARG YAPB_VERSION=4.4.957

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl libstdc++6 libgcc-s1 zlib1g tar unzip xz-utils python3 \
 && rm -rf /var/lib/apt/lists/*

# Dedicated server binary + filesystem module (see FWGS/xash3d-fwgs releases).
RUN mkdir -p /opt/xash \
 && curl -fsSL "https://github.com/FWGS/xash3d-fwgs/releases/download/${XASH_TAG}/xashds-linux-i386.tar.gz" \
    | tar -xz -C /opt/xash --strip-components=1 \
 && chmod +x /opt/xash/xash

# ReGameDLL: open-source CS 1.6 game rules (bug fixes, no gameplay rewrite).
RUN curl -fsSL -o /tmp/regamedll.zip \
      "https://github.com/s1lentq/ReGameDLL_CS/releases/download/${REGAMEDLL_VERSION}/regamedll-bin-${REGAMEDLL_VERSION}.zip" \
 && mkdir -p /opt/regamedll \
 && unzip -q /tmp/regamedll.zip 'bin/linux32/*' -d /opt/regamedll \
 && rm /tmp/regamedll.zip \
 && test -f /opt/regamedll/bin/linux32/cstrike/dlls/cs.so

# YaPB: bot open-source (standalone plugin — engine nạp nó qua liblist, nó tự
# chain tới ReGameDLL dlls/cs.so; graph từng map tải qua HTTPS khi chơi).
RUN curl -fsSL -o /tmp/yapb.tar.xz \
      "https://github.com/yapb/yapb/releases/download/${YAPB_TAG}/yapb-${YAPB_VERSION}-linux.tar.xz" \
 && mkdir -p /opt/yapb \
 && tar -xJf /tmp/yapb.tar.xz -C /opt/yapb \
 && rm /tmp/yapb.tar.xz \
 && test -f /opt/yapb/addons/yapb/bin/yapb.so

# KZ mode (KZ_MODE=1): metamod-p + AMX Mod X (base + cstrike) cho plugin
# ProKreedz — checkpoints/timer/teleport cho map parkour. Bots TẮT trong mode này.
RUN curl -fsSL -o /tmp/metamod.tar.xz \
      "https://github.com/Bots-United/metamod-p/releases/download/v1.21p109/metamod-p-v1.21p109-linux_ubuntu2404.tar.xz" \
 && mkdir -p /opt/metamod \
 && tar -xJf /tmp/metamod.tar.xz -C /opt/metamod \
 && rm /tmp/metamod.tar.xz \
 && test -f /opt/metamod/addons/metamod/dlls/metamod.so \
 && curl -fsSL -o /tmp/amxx-base.tar.gz \
      "https://github.com/alliedmodders/amxmodx/releases/download/1.10.0.5487/amxmodx-1.10.0-git5487-base-linux.tar.gz" \
 && curl -fsSL -o /tmp/amxx-cstrike.tar.gz \
      "https://github.com/alliedmodders/amxmodx/releases/download/1.10.0.5487/amxmodx-1.10.0-git5487-cstrike-linux.tar.gz" \
 && mkdir -p /opt/amxx \
 && tar -xzf /tmp/amxx-base.tar.gz -C /opt/amxx \
 && tar -xzf /tmp/amxx-cstrike.tar.gz -C /opt/amxx \
 && rm /tmp/amxx-*.tar.gz \
 && test -f /opt/amxx/addons/amxmodx/dlls/amxmodx_mm_i386.so

COPY docker/game-entrypoint.sh /usr/local/bin/game-entrypoint.sh
COPY config/server.cfg /opt/config/server.cfg
COPY config/motd.txt /opt/config/motd.txt
COPY config/liblist.gam /opt/config/liblist.gam
COPY config/presets.json /opt/config/presets.json
COPY config/resource /opt/config/resource
COPY config/amxx-plugins /opt/config/amxx-plugins
COPY game/supervisor.py /opt/supervisor.py
RUN chmod +x /usr/local/bin/game-entrypoint.sh

# Chế độ dashboard nhiều phòng: entrypoint chạy supervisor (ROOMS_API=1) thay
# vì 1 server tĩnh; web container gọi qua GAME_MGR=http://game:7000.
ENV ROOMS_API=1
ENV ROOMS_FILE=/data/rooms.json
ENV LISTEN_PORT=7000
ENV UDP_BASE=27015
ENV EMPTY_TTL=1800
EXPOSE 7000
EXPOSE 27015-27050/udp
ENTRYPOINT ["/usr/local/bin/game-entrypoint.sh"]
