# Agent Quickstart

You are an AI agent in Captain Sydney's homelab. This document tells you the bare minimum to bootstrap — how to reach the shared knowledge vault where the full onboarding docs live.

## 1. Read the onboarding guide

The agent collective maintains a shared Obsidian vault via Caldera. Start here:

| What | Value |
|------|-------|
| **URL** | `http://192.168.10.85:8000/api/v1` |
| **Auth** | `Bearer 9e6497c672ac465f0b842305fd46a2b2eabeccdf794c2a9b0e560fd723d0c7af` |
| **Swagger** | `http://192.168.10.85:8000/docs` |

Read the onboarding guide:

```python
import urllib.request, json

API_KEY = "9e6497c672ac465f0b842305fd46a2b2eabeccdf794c2a9b0e560fd723d0c7af"
BASE = "http://192.168.10.85:8000/api/v1"

req = urllib.request.Request(f"{BASE}/notes/Onboarding%20Guide.md")
req.add_header("Authorization", f"Bearer {API_KEY}")
with urllib.request.urlopen(req) as resp:
    guide = json.loads(resp.read())

print(guide["content"])
```

The onboarding guide will point you to four required-reading notes: MQTT Protocol, Caldera API, Agent Registry, and Task Delegation. Read them all.

## 2. Register yourself

Once you understand the system, register in the Agent Registry and publish your first heartbeat. The onboarding guide has the steps.

## 3. Rules

These are non-negotiable:

1. **Never message users proactively.** Discord `require_mention` must be `true`. You respond, you don't initiate.
2. **All infrastructure changes must be IaC-backed** via FluxCD in this repo. No `kubectl apply` directly.
3. **Write postmortems** to the shared vault after any incident or unusual event.
4. **Do not use the shared vault for real-time chat.** That's what MQTT is for. The vault is durable knowledge.
5. **Prefer OpenCode with DeepSeek** for coding tasks.

## 4. Key services

| Service | Address | Purpose |
|---------|---------|---------|
| Caldera (agents) | `192.168.10.85:8000` | Shared knowledge vault |
| Caldera (personal) | `192.168.10.70:8000` | Captain's private vault — read-only unless asked |
| MQTT Broker | `192.168.10.72:1883` | Real-time agent comms |
| MQTT Explorer | `192.168.10.81:80` | Debug MQTT in a browser |
| Home Assistant | `192.168.10.147:8123` | Smart home control |

Full service catalog and operational details are in the Caldera vault and the `homelab-ops` skill.

## 5. Other agents

| Agent | Role | MQTT inbox |
|-------|------|------------|
| **Guppy** | Primary operations AI | `homelab/agents/guppy/inbox` |
| **Jeeves** | Secondary worker AI | `homelab/agents/jeeves/inbox` |

Full registry in the Caldera vault → Agent Registry note.
