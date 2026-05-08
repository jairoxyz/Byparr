# syntax=docker/dockerfile:1

# ------------------------------------------------------------------------------
# Base: minimal OS + uv/uvx
# ------------------------------------------------------------------------------
FROM ubuntu:22.04 AS base

ARG GITHUB_BUILD=false
ARG VERSION

ENV GITHUB_BUILD=${GITHUB_BUILD} \
    VERSION=${VERSION} \
    DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_LINK_MODE=copy \
    PORT=8191

# Minimal runtime packages:
# - ca-certificates: HTTPS/TLS
# - curl: healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl \
    # X11/XCB
    libx11-6 libx11-xcb1 libxcb1 libxcb-shm0 \
    libxcomposite1 libxdamage1 libxext6 libxfixes3 libxrandr2 libxrender1 \
    libxcursor1 libxi6 \
    # GTK / GLib / Pango / Cairo
    libgtk-3-0 \
    libglib2.0-0 \
    libpango-1.0-0 libpangocairo-1.0-0 \
    libatk1.0-0 \
    libcairo2 libcairo-gobject2 \
    libgdk-pixbuf2.0-0 \
    # Fonts/rendering libs
    libfreetype6 libfontconfig1 \
    # Audio + DBus
    libasound2 libdbus-1-3 \
    && rm -rf /var/lib/apt/lists/*

# Bring uv/uvx binaries in
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Create an unprivileged user deterministically (UID/GID 1000)
# (ubuntu:22.04 does NOT include an "ubuntu" user by default)
RUN groupadd -g 1000 app && \
    useradd  -m -u 1000 -g 1000 -s /bin/bash app


# ------------------------------------------------------------------------------
# Devcontainer: tools for interactive development (does NOT affect final image)
# ------------------------------------------------------------------------------
FROM base AS devcontainer

WORKDIR /app

# Dev tools (keep minimal; add more as needed)
RUN apt-get update && apt-get install -y --no-install-recommends \
      git \
    && rm -rf /var/lib/apt/lists/*

# Optional: set a stable cache location (nice for dev too)
ENV XDG_CACHE_HOME=/cache
RUN mkdir -p /cache && chown -R app:app /cache

USER app

# Optional (uncomment if you want camoufox ready in devcontainer by default)
# COPY pyproject.toml uv.lock ./
# RUN uv sync --frozen && uv run camoufox fetch && uv cache clean
# USER root
# RUN echo "/cache/camoufox" > /etc/ld.so.conf.d/camoufox.conf && ldconfig
# USER app

ENTRYPOINT ["sleep", "infinity"]


# ------------------------------------------------------------------------------
# App build: install runtime deps + fetch camoufox + register libs + copy code
# ------------------------------------------------------------------------------
FROM base AS app

WORKDIR /app
RUN chown -R app:app /app

# Put caches in a stable, non-home location
ENV XDG_CACHE_HOME=/cache

# Prepare cache dir (writable by runtime user)
RUN mkdir -p /cache && chown -R app:app /cache

# Install Python deps first (best layer caching)
COPY pyproject.toml uv.lock ./

USER app

# Create venv + install deps (no dev group) and fetch camoufox into cache.
# --frozen ensures uv.lock is authoritative/reproducible.
RUN uv sync --frozen --no-dev && \
    uv run camoufox fetch && \
    uv cache clean

# Register camoufox bundled shared libs with ldconfig (your proven working fix).
# IMPORTANT: this path must be the directory containing libxul.so and friends.
USER root
RUN echo "/cache/camoufox" > /etc/ld.so.conf.d/camoufox.conf && ldconfig

USER app

# Copy application code last (preserves dependency layer cache)
COPY . .


# ------------------------------------------------------------------------------
# Test stage: installs test group and runs pytest (not in final image)
# ------------------------------------------------------------------------------
FROM app AS test

# If your project uses dependency groups (PEP 735), this will install test deps.
# If not, adjust to your project's scheme (extras, requirements, etc.).
RUN uv sync --frozen --group test && \
    uv run pytest --retries 3


# ------------------------------------------------------------------------------
# Final runtime image (default): lean, non-root, runs the app
# ------------------------------------------------------------------------------
FROM app AS final

USER app
EXPOSE 8191

HEALTHCHECK --interval=15m --timeout=30s --start-period=5s --retries=3 \
  CMD curl -fsS "http://localhost:8191/health" || exit 1

ENTRYPOINT ["/app/.venv/bin/python", "main.py"]