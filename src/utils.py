import logging
import time
from collections.abc import AsyncGenerator
from typing import Annotated, NamedTuple, cast, Optional, Tuple, Awaitable, Callable
from types import MethodType
from dataclasses import dataclass

from camoufox import AsyncCamoufox
from fastapi import Header
from playwright.async_api import Browser, BrowserContext, Page
from playwright_captcha import (
    ClickSolver,
    FrameworkType,
)
from pydantic import BaseModel, Field

from src.consts import (
    ADDON_PATH,
    LOG_LEVEL,
    MAX_ATTEMPTS,
    PROXY_PASSWORD,
    PROXY_SERVER,
    PROXY_USERNAME,
)

solver_logger = logging.getLogger("playwright_captcha")
solver_logger.handlers.clear()
if LOG_LEVEL == logging.DEBUG:
    solver_logger.addHandler(logging.StreamHandler())
    solver_logger.setLevel(LOG_LEVEL)
else:
    solver_logger.handlers.append(logging.NullHandler())

logger = logging.getLogger("uvicorn.error")
logger.setLevel(LOG_LEVEL)
if len(logger.handlers) == 0:
    logger.addHandler(logging.StreamHandler())


class TimeoutTimer(BaseModel):
    duration: int  # in seconds
    start_time: float = Field(default_factory=time.perf_counter)

    def remaining(self) -> float:
        """Get remaining time in seconds."""
        return max(0, self.duration - (time.perf_counter() - self.start_time))


@dataclass
class CamoufoxDepClass:
    page: Page
    solver: ClickSolver
    context: BrowserContext

    # injected by get_camoufox
    _switch_impl: Optional[Callable[[], Awaitable[Tuple[Page, BrowserContext]]]] = None

    async def switch_to_clean(self) -> Tuple[Page, BrowserContext]:
        if self._switch_impl is None:
            raise RuntimeError("switch_to_clean() not initialized by get_camoufox")
        return await self._switch_impl()


@dataclass
class _CleanHandle:
    cm: AsyncCamoufox
    browser_raw: object
    context: BrowserContext
    page: Page


async def get_camoufox(
    x_proxy_server: Annotated[
        str | None,
        Header(
            alias="X-Proxy-Server",
            description="Override proxy server for this request in protocol://host:port format.",
        ),
    ] = None,
    x_proxy_username: Annotated[
        str | None,
        Header(
            alias="X-Proxy-Username",
        ),
    ] = None,
    x_proxy_password: Annotated[
        str | None,
        Header(
            alias="X-Proxy-Password",
        ),
    ] = None,
) -> AsyncGenerator[CamoufoxDepClass, None]:
    """Get Camoufox instance."""
    header_server = x_proxy_server
    header_username = x_proxy_username
    header_password = x_proxy_password

    proxy_config = None

    if header_server:
        proxy_config = {
            "server": header_server,
            "username": header_username,
            "password": header_password,
        }
    elif PROXY_SERVER:
        proxy_config = {
            "server": PROXY_SERVER,
            "username": PROXY_USERNAME,
            "password": PROXY_PASSWORD,
        }

    async with AsyncCamoufox(
        main_world_eval=True,
        addons=[ADDON_PATH],
        geoip=True,
        proxy=proxy_config,
        locale="en-US",
        headless=True,
        humanize=True,
        i_know_what_im_doing=True,
        config={"forceScopeAccess": True},  # add this when creating Camoufox instance
        disable_coop=True,  # add this when creating Camoufox instance
    ) as browser_raw:
        # Cast to Browser since AsyncCamoufox always returns a Browser, not BrowserContext
        browser = cast("Browser", browser_raw)
        context = await browser.new_context()
        page = await context.new_page()

        # Track clean instance (if ever created) so we can close it on teardown
        clean_handle: Optional[_CleanHandle] = None

        async with ClickSolver(
            framework=FrameworkType.CAMOUFOX,
            page=page,
            max_attempts=MAX_ATTEMPTS,
            attempt_delay=1,
        ) as solver:
            # yield CamoufoxDepClass(page, solver, context)

            dep = CamoufoxDepClass(page=page, solver=solver, context=context)

            '''implement switch_to_clean camoufox with without techinz/camoufox-add_init_script
               addon, which blocks fake page injection and breaks cfts solver in endpoint.
               Clean camoufox also runs without captcha solver plugins loaded into the main CamoufoxDepClass
            '''
            # ---- Closure implementation for switch_to_clean injected into dep._switch_impl ----
            async def _switch_impl() -> Tuple[Page, BrowserContext]:
                nonlocal clean_handle

                # If already switched, reuse
                if clean_handle is not None:
                    return clean_handle.page, clean_handle.context

                # 1) Snapshot session from HEAVY context (cookies + localStorage)
                state = await dep.context.storage_state()

                # 2) Launch CLEAN camoufox (NO addons), keep SAME proxy + geoip=True
                cm = AsyncCamoufox(
                    proxy=proxy_config,
                    geoip=True,
                    locale="en-US",
                    headless=True,
                    humanize=True,  # is faster with False
                    main_world_eval=True
                    # IMPORTANT: no addons=[ADDON_PATH] here
                )
                browser2_raw = await cm.__aenter__()
                browser2 = cast(Browser, browser2_raw)

                clean_context = await browser2.new_context(storage_state=state)
                clean_page = await clean_context.new_page()

                clean_handle = _CleanHandle(
                    cm=cm,
                    browser_raw=browser2_raw,
                    context=clean_context,
                    page=clean_page,
                )

                # 3) Close HEAVY context so addon can’t affect subsequent work
                try:
                    await dep.context.close()
                except Exception:
                    pass

                return clean_page, clean_context

            # inject implementation (no MethodType)
            dep._switch_impl = _switch_impl

            try:
                yield dep

            finally:
                # ---- teardown clean if created ----
                if clean_handle is not None:
                    try:
                        await clean_handle.context.close()
                    except Exception:
                        pass
                    try:
                        await clean_handle.cm.__aexit__(None, None, None)
                    except Exception:
                        pass

                # ---- teardown heavy context (if not already closed) ----
                try:
                    await context.close()
                except Exception:
                    pass
