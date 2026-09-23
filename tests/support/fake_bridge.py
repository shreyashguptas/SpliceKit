"""A recording stand-in for `module.bridge.call` in the offline tests.

    with FakeBridge(module, lambda method, params: {"status": "ok"}) as fake:
        module.seek_to_time(3.0)
    fake.calls  ->  [("playback.seekToTime", {"seconds": 3.0})]

It accepts every way the server calls the bridge (keyword params, a positional params
dict, or both, merged the way BridgeConnection.call merges them) and records each call as
(method, params). A per-call `timeout=` stays in params, as the hand-written fakes kept
it; separate_timeout=True records (method, params, timeout) instead, timeout None when
the call gave none. The original `bridge.call` is put back on exit / restore().
"""


class FakeBridge:
    def __init__(self, module, responder=None, *, separate_timeout=False):
        """`responder(method, params)` returns the answer; a non-callable responder is the
        answer to every call; None answers {}."""
        self.module = module
        self.responder = responder
        self.separate_timeout = separate_timeout
        self.calls = []
        self._original = None

    def __call__(self, method, params_dict=None, /, **params):
        timeout = params.pop("timeout", None) if self.separate_timeout else None
        merged = {**params_dict, **params} if isinstance(params_dict, dict) else dict(params)
        if self.separate_timeout:
            self.calls.append((method, merged, timeout))
        else:
            self.calls.append((method, merged))
        if callable(self.responder):
            return self.responder(method, merged)
        return {} if self.responder is None else self.responder

    def install(self):
        self._original = self.module.bridge.call
        self.module.bridge.call = self
        return self

    def restore(self):
        if self._original is not None:
            self.module.bridge.call = self._original
            self._original = None

    def __enter__(self):
        return self.install()

    def __exit__(self, *exc):
        self.restore()
        return False


class FakeBridgeMixin:
    """For a TestCase whose `self.module` is a server from load_server_module():
    `calls = self._install_bridge(responder)` installs a FakeBridge for this test and
    puts the real bridge.call back when the test ends."""

    def _install_bridge(self, responder=None, **kwargs):
        fake = FakeBridge(self.module, responder, **kwargs).install()
        self.addCleanup(fake.restore)
        return fake.calls
