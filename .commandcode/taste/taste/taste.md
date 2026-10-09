# Taste
- Prefers dogfooding as a validation method: when a tool/engine is being built or improved, run it against its own codebase to surface real defects before calling the work done ("直接用这个引擎检查他自己的代码置信度"). Confidence: 0.6
- Wants a review pass before optimization work — audit first, then act on findings, rather than jumping straight to changes. Confidence: 0.5
- Expects work to reach the remote: "commit" means commit AND push, keeping local branches in sync with origin. Confidence: 0.5
- Prefers strict fast-forward integration (`--ff-only`, no merge commits/conflicts) when landing a feature branch onto his working branch. Confidence: 0.5
- Gives extremely terse instructions in Chinese (e.g. "提交推送") and expects the agent to work out the full workflow; only asks for clarification when the action is shared/hard-to-reverse. Confidence: 0.5
- Dislikes shallow implementations and pushes for depth ("现在整个模块都太简单了"); expects a "deep review and optimization", not a minimal surface fix. Confidence: 0.5
- Expects the language's native strengths to be exploited — for performance/scale problems he reaches for Cangjie's concurrency (协程/线程) rather than working around it ("仓颉是有这能力的，而且很强"). Confidence: 0.5
