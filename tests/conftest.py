import pytest
import os
from pathlib import Path

FIXTURES_DIR = Path(__file__).parent / "fixtures"
SCRIPTS_DIR = Path(__file__).parent.parent / "scripts"
PROJECT_ROOT = Path(__file__).parent.parent


@pytest.fixture
def opencode_fixtures_dir():
    return FIXTURES_DIR / "opencode"


@pytest.fixture
def claude_fixtures_dir():
    return FIXTURES_DIR / "claude-code"


@pytest.fixture
def expected_dir():
    return FIXTURES_DIR / "expected"
