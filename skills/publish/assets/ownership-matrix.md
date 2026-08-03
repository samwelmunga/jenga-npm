# Publish Agent Ownership Matrix

The `/publish` skill is initiated by the operator running the CLI, but each action has a defined workflow owner inside the multi-agent system.

| Action | Developer | Tester | Scrum Master |
|---|---|---|---|
| `/publish setup` | Initiates and owns | May run to configure test targets | Never |
| `/publish deploy --target staging` | Initiates | May run as part of test cycle | Never directly |
| `/publish deploy --target production` | Initiates with explicit confirmation | Reviews ledger entry post-deploy | Reviews `/status` only |
| `/publish history` | Reads for context | Reads for test baseline | Reads in `/status` review |
| `/publish release-notes` | Generates and reviews draft | May read draft for test context | Reviews content for sprint summary |
| Gate failure resolution | Owns rework | Validates rework | Escalates if blocked |
| Ledger entry disputes | Never modifies | Never modifies | Flags as rapport; human resolves |

## Trust boundary

The `mobile-ios` adapter may only execute direct `xcodebuild` and `xcrun` commands. Arbitrary shell commands are not permitted inside the adapter pipeline.
