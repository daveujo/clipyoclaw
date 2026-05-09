# Paperclip / HuggingClip

## LLM provider support

This project is now simplified to focus on NVIDIA/OpenCode usage.

### Supported runtime secrets

- `NVIDIA_API_KEYS` or `NVIDIA_API_KEY`
- `NVIDIA_PROVIDER_JSON` or `NVIDIA_PROVIDER_JSON_FILE`
- `OPENCODE_API_KEY`

### Not used anymore

The following provider keys and wrapper paths have been removed from the runtime setup:

- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `CLAUDE_CODE_OAUTH_TOKEN`
- Claude wrapper logic
- OpenAI/Codex provider-specific startup branches

### Notes

If you still see references to those providers elsewhere, they are legacy docs or leftover configuration and should be removed in a follow-up cleanup.
