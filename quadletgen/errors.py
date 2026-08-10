# ABOUTME: Defines errors shared across the independent configuration domains.

"""Configuration errors raised by parsers, models, and compilers."""


class ConfigError(ValueError):
    """Raised when a service or fleet configuration violates its contract."""
