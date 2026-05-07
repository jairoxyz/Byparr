# Ubuntu is required by playwright
FROM ubuntu:22.04 AS base

ARG GITHUB_BUILD=false \
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
RUN apt install -y git &&\
    uvx playwright install-deps firefox &&\
    uvx camoufox fetch
ENTRYPOINT [ "sleep", "infinity" ]

FROM base AS app
WORKDIR /app
RUN chown ${USER}:${GROUP} /app &&\
    mkdir -p ${UV_CACHE_DIR} &&\
    chown ${USER}:${GROUP} ${UV_CACHE_DIR}

USER ${USER}
COPY pyproject.toml uv.lock ./
RUN uv sync && uv run camoufox fetch

USER root
RUN uv run playwright install-deps firefox
USER ${USER}

# add camoufox ld lib path
USER root
RUN echo "/home/${USER}/.cache/camoufox" > /etc/ld.so.conf.d/camoufox.conf && ldconfig
USER ${USER}

COPY . .

FROM app AS test
RUN \
    uv sync --group test &&\
    uv run pytest --retries 3

FROM app
EXPOSE $PORT
HEALTHCHECK --interval=15m --timeout=30s --start-period=5s --retries=3 CMD curl "http://localhost:${PORT}/health"
ENTRYPOINT ["uv", "run", "main.py"]
