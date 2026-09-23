"""SpliceKit's MCP tools, one module per area.

Importing a module registers its tools with the MCPServer (`app.mcp`), and clients
list tools in registration order. The imports below are therefore in the order the
tools were defined in the single-file server; keep new modules in a deliberate place.
"""

from . import system  # noqa: F401
from . import timeline_actions  # noqa: F401
from . import scene  # noqa: F401
from . import timeline_reads  # noqa: F401
from . import objects  # noqa: F401
from . import fcpxml  # noqa: F401
from . import timeline_batch  # noqa: F401
from . import markers  # noqa: F401
from . import song_cut  # noqa: F401
from . import srt  # noqa: F401
from . import library  # noqa: F401
from . import runtime  # noqa: F401
from . import transcript  # noqa: F401
from . import effects  # noqa: F401
from . import palette  # noqa: F401
from . import ui  # noqa: F401
from . import mixer  # noqa: F401
from . import projects  # noqa: F401
from . import edit  # noqa: F401
from . import clip_info  # noqa: F401
from . import audio_levels  # noqa: F401
from . import capture  # noqa: F401
from . import interchange  # noqa: F401
from . import dev  # noqa: F401
from . import ui_state  # noqa: F401
from . import music  # noqa: F401
from . import montage  # noqa: F401
from . import debug  # noqa: F401
from . import direct_actions  # noqa: F401
from . import browser  # noqa: F401
from . import captions  # noqa: F401
from . import lua  # noqa: F401
from . import plugins  # noqa: F401
from . import batch  # noqa: F401
