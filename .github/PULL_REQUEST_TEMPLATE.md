## Summary

<!-- What does this change and why? Link the issue it closes, if any. -->

Closes #

## Type of change

- [ ] Bug fix
- [ ] New feature / layer
- [ ] Refactor (no behavior change)
- [ ] Documentation
- [ ] CI / tooling

## Checklist

- [ ] `uv run ruff check src tests`, `uv run mypy src`, and `uv run pytest` pass
- [ ] `shellcheck` clean on any touched `.sh` file
- [ ] `sqlfluff lint` clean on any touched `.sql` file
- [ ] `hadolint` clean on any touched Dockerfile
- [ ] New layers were added via `config/layers.yml` (not bash) and verified
      with `rbt tiles --layer <key> --dry-run`
- [ ] Docs updated for any user-visible change; new config keys documented in
      `docs/configuration.md`
- [ ] No internal hostnames, IPs, or credentials introduced
