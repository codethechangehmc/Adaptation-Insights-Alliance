"""Run one source or helper: python rag-pipeline/scraper/run.py COMMAND [options]."""

from __future__ import annotations

import argparse
import importlib

SOURCE_MODULES = {
    "worldbank": "sources.worldbank",
    "af": "sources.af",
    "afdb": "sources.afdb",
    "cif": "sources.cif",
    "gcf": "sources.gcf",
    "gef": "sources.gef",
    "ifad": "sources.ifad",
}
HELPER_MODULES = {
    "worldbank_projects": "helpers.worldbank_projects",
    "gef_doc_dates": "helpers.gef_doc_dates",
}
COMMANDS = {**SOURCE_MODULES, **HELPER_MODULES}

# run_all order: project details refresh right after the World Bank catalogue it reads.
# GEF date recovery is left out: it needs downloaded files and optional PyMuPDF.
BATCH_COMMANDS = ["worldbank", "worldbank_projects", "af", "afdb", "cif", "gcf", "gef", "ifad"]


def main(argv: list[str] | None = None) -> int:
    """Select a command and pass its options to that source or helper."""
    # Leave command-specific options, including --help, to that command's parser.
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=COMMANDS)
    parser.add_argument("options", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)

    # Import only the selected module. Helpers have their own main; sources use the runner.
    module = importlib.import_module(COMMANDS[args.command])
    if args.command in HELPER_MODULES:
        return module.main(args.options)

    from core import runner

    return runner.main(module, args.options)


if __name__ == "__main__":
    raise SystemExit(main())
