# Ubuntu is required by playwright
FROM ubuntu:22.04 AS base

ARG GITHUB_BUILD=false \
    VERSION
    UV_CACHE_DIR=/var/cache/uv \
    VERSION \
    USER=ubuntu \
    UID=1000 

ARG GROUP=${USER} \
    GID=${UID}

ENV GITHUB_BUILD=${GITHUB_BUILD}\
    VERSION=${VERSION}\
    DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    # prevents python creating .pyc files
    PYTHONDONTWRITEBYTECODE=1 \
    UV_LINK_MODE=copy \
    PORT=8191 \
    XDG_CACHE_HOME=/cache \
    HOME=/tmp

RUN apt-get update &&\
    apt-get install -y --no-install-recommends curl ca-certificates &&\
    apt-get clean &&\
    rm -rf /var/lib/apt/lists/*
    UV_CACHE_DIR=${UV_CACHE_DIR} \
    PORT=8191 

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl \
    # Firefox/Camoufox core runtime deps
    # libgtk-3-0 \
    # libnss3 libnspr4 \
    # libasound2 \
    # libx11-xcb1 \
    # # commonly required by Firefox builds
    # libdbus-glib-1-2 \
    # libatk1.0-0 libatk-bridge2.0-0 \
    # libcairo2 libpango-1.0-0 \
    # libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    # libxshmfence1 libxkbcommon0 \
    # libcups2 \
    # libdrm2 libgbm1 \
    # fonts-liberation \
 && rm -rf /var/lib/apt/lists/*


# Non-root user ubuntu doesn't exist in all ubuntu base images
RUN groupadd -g ${GID} ${GROUP} && \
    useradd -m -u ${UID} -g ${GROUP} -s /bin/bash ${USER}


COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

FROM base AS devcontainer
RUN apt-get update &&\
    apt-get install -y --no-install-recommends git &&\
    uvx playwright install-deps firefox &&\
    uvx camoufox fetch &&\
    apt-get clean &&\
    rm -rf /var/lib/apt/lists/*
ENTRYPOINT [ "sleep", "infinity" ]

FROM base AS app
WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN mkdir -p /cache &&\
    uv sync &&\
    uv run camoufox fetch &&\
    apt-get update &&\
    uv run playwright install-deps firefox &&\
    uv cache clean &&\
    apt-get clean &&\
    rm -rf /var/lib/apt/lists/*

# add camoufox ld lib path
USER root
RUN echo "/home/${USER}/.cache/camoufox" > /etc/ld.so.conf.d/camoufox.conf && ldconfig
USER ${USER}

COPY . .

# Make app and cache world-readable; addon scripts dir world-writable (runtime writes)
RUN chmod -R o+rX /app /cache &&\
    find /app/.venv -path "*/camoufox_add_init_script/addon" -type d -exec chmod -R o+rwX {} +

FROM app AS test
RUN \
    uv sync --group test &&\
    uv run pytest --retries 3

FROM app
USER 1000
EXPOSE $PORT
HEALTHCHECK --interval=15m --timeout=30s --start-period=5s --retries=3 CMD curl "http://localhost:${PORT}/health"
ENTRYPOINT ["/app/.venv/bin/python", "main.py"]
