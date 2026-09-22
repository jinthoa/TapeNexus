"""PyInstaller entry shim — imports and runs the tapenexus package."""
from tapenexus import main

raise SystemExit(main())