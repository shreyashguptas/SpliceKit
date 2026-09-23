"""Load mcp/server.py (and the splicekit_mcp package behind it) under a fake MCP SDK.

The offline tests run without the `mcp` package: the fakes below stand in for the
mcp 2.x classes the server imports and record every tool, resource and prompt it
registers. Each load_server_module() call purges the splicekit_mcp modules first, so
every test class gets a fresh server (its own MCPServer, bridge and tool list), just as
exec'ing the single-file server did.

The server's names live in the package modules; mcp/server.py re-exports them, so
`module.get_timeline_clips` and `module.bridge.call = fake` work as before. Rebinding a
module global (module.Image = ...) on the re-exported namespace changes nothing inside
the package; use set_package_global() to rebind it in the modules that use it.
"""
import importlib.util
import sys
import types
from pathlib import Path

PACKAGE = "splicekit_mcp"


# Wire spellings of the ToolAnnotations fields (what an MCP client receives).
_ANNOTATION_ALIASES = {
    "read_only_hint": "readOnlyHint",
    "destructive_hint": "destructiveHint",
    "idempotent_hint": "idempotentHint",
    "open_world_hint": "openWorldHint",
    "title": "title",
}


class FakeToolAnnotations(dict):
    """Stands in for mcp.types.ToolAnnotations (mcp 2.x): built with snake_case keyword
    arguments like the real model, readable by the tests under the camelCase names the
    real model serializes to (model_dump(by_alias=True))."""

    def __init__(self, **kwargs):
        unknown = set(kwargs) - set(_ANNOTATION_ALIASES)
        if unknown:
            raise TypeError(f"unexpected ToolAnnotations fields: {sorted(unknown)}")
        super().__init__({_ANNOTATION_ALIASES[k]: v for k, v in kwargs.items()})

    def model_dump(self, by_alias=True, exclude_none=True):
        return dict(self)


class FakeToolError(Exception):
    """Stands in for mcp.server.mcpserver.exceptions.ToolError."""


class FakeMCPServer:
    """Stands in for mcp.server.mcpserver.MCPServer (mcp 2.x): records every tool,
    resource and prompt registration so the tests can inspect them without the SDK."""

    def __init__(self, name=None, title=None, description=None, instructions=None,
                 website_url=None, icons=None, version="", **kwargs):
        self.name = name
        self.instructions = instructions
        self.version = version
        self.tools = []
        self.resources = []
        self.prompts = []
        self._tool_manager = types.SimpleNamespace(list_tools=lambda: [])

    def tool(self, name=None, title=None, description=None, annotations=None, **kwargs):
        def decorator(func):
            self.tools.append(
                {
                    "name": name or func.__name__,
                    "annotations": dict(annotations or {}),
                    "func": func,
                }
            )
            return func

        return decorator

    def resource(self, uri, **kwargs):
        def decorator(func):
            self.resources.append({"uri": uri, "func": func, **kwargs})
            return func
        return decorator

    def prompt(self, **kwargs):
        def decorator(func):
            self.prompts.append({"func": func, **kwargs})
            return func
        return decorator


# Kept under the old name for tests written against it.
FakeFastMCP = FakeMCPServer


def load_server_module():
    repo_root = Path(__file__).resolve().parents[2]
    module_path = repo_root / "mcp" / "server.py"

    # The layout of the mcp 2.x package that mcp/server.py imports from. The fake
    # mcpserver module has no Image attribute on purpose: the server treats a missing
    # Image helper as "return text instead of inline images" and the tests rely on that.
    fake_mcp = types.ModuleType("mcp")
    fake_mcp_server = types.ModuleType("mcp.server")
    fake_mcpserver = types.ModuleType("mcp.server.mcpserver")
    fake_mcpserver.MCPServer = FakeMCPServer
    fake_types = types.ModuleType("mcp.types")
    fake_types.ToolAnnotations = FakeToolAnnotations
    fake_exceptions = types.ModuleType("mcp.server.mcpserver.exceptions")
    fake_exceptions.ToolError = FakeToolError

    injected_modules = {
        "mcp": fake_mcp,
        "mcp.server": fake_mcp_server,
        "mcp.server.mcpserver": fake_mcpserver,
        "mcp.server.mcpserver.exceptions": fake_exceptions,
        "mcp.types": fake_types,
    }
    previous_modules = {name: sys.modules.get(name) for name in injected_modules}

    try:
        sys.modules.update(injected_modules)
        purge_package_modules()

        spec = importlib.util.spec_from_file_location("splicekit_mcp_server_under_test", module_path)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        module._package_modules = _package_modules_now()
        return module
    finally:
        for name, previous in previous_modules.items():
            if previous is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = previous



def purge_package_modules():
    """Forget every imported splicekit_mcp module, so the next import builds them anew."""
    for name in list(sys.modules):
        if name == PACKAGE or name.startswith(PACKAGE + "."):
            del sys.modules[name]


def _package_modules_now():
    return {name: mod for name, mod in sys.modules.items()
            if name == PACKAGE or name.startswith(PACKAGE + ".")}


def package_module(module, name):
    """The splicekit_mcp submodule `name` ("images", "tools.music", ...) that belongs to
    the server `module` returned by load_server_module()."""
    return module._package_modules[f"{PACKAGE}.{name}"]


def set_package_global(module, name, value):
    """Rebind the global `name` in every splicekit_mcp module of this server that binds it
    (where it is defined and where it was imported), and in the re-exported namespace.
    Returns the module names that were patched."""
    patched = []
    for mod_name, mod in module._package_modules.items():
        if name in vars(mod):
            setattr(mod, name, value)
            patched.append(mod_name)
    if not patched:
        raise AttributeError(f"no splicekit_mcp module binds {name!r}")
    setattr(module, name, value)
    return patched
