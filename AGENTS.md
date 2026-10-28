# AGENTS.md

Guidance for the AI agents that work on this repository. Claude Code, OpenAI Codex
and Gemini all read this file. Edit it to describe your project: the agents follow
what is written here, so the more specific it is, the closer their work is to how
your team would do it.

Safety rules do not live here. The agent workflows put them in each prompt, so
replacing this file cannot remove them.

## Project

<!-- One paragraph: what this repository is and who uses it. -->

## Conventions

<!-- How code here is written. Name the patterns to copy, with file paths. -->

- Follow the patterns of the code around the change. Read the files named in the
  issue's Technical Notes before writing anything.
- Keep changes inside the issue's scope. "Out of scope" is a hard boundary.

## Commands

<!-- The exact commands for this project. Agents use them to check their work. -->

| Task | Command |
|---|---|
| Install | <!-- e.g. npm ci / composer install --> |
| Test | <!-- e.g. npm test / vendor/bin/phpunit --> |
| Lint | <!-- e.g. npm run lint / vendor/bin/phpcs --> |

## Definition of done

- Every acceptance criterion in the issue is met, or the gap is stated plainly.
- Tests are added or updated for the behaviour that changed.
- Anything that could not be verified is listed for the reviewer, not left implied.
