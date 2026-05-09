---
title: Paperclip
emoji: 📎
colorFrom: gray
colorTo: purple
sdk: docker
app_port: 7861
pinned: true
license: mit
secrets:
  - name: HF_TOKEN
    description: Hugging Face API token for database backup.
  - name: OPENCODE_API_KEY
    description: OpenCode API key for OpenCode-powered agents.
  - name: NVIDIA_API_KEYS
    description: NVIDIA NIM API key list (single secret; comma/newline-separated) from build.nvidia.com
  - name: NVIDIA_PROVIDER_JSON
    description: Optional NVIDIA model/provider JSON.
  - name: CLOUDFLARE_WORKERS_TOKEN
    description: "Cloudflare API token — auto-creates a Worker proxy and KeepAlive monitor."
---

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
