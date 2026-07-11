# Live skill-evaluation protocol (v1)

Static routing fixtures remain the fast regression check. This protocol records
operator-observed, fresh-session behavior; it is not satisfied by metadata,
simulated probes, or a model's self-report.

For each changed runtime/model combination, record the runtime CLI version,
model identifier, date, exact prompt, selected skill/phase, observable result,
and pass/fail verdict. Store a concise record beside the relevant release
attestation or link it from that attestation.

Run at least one success and one rejection/boundary case for each affected
skill. Maintain these phase-boundary cases:

| Boundary | Success evidence | Failure evidence |
|---|---|---|
| plan vs implement | underspecified goal selects `b-plan`; approved scoped edit selects `b-implement` | implementation starts before scope/approval |
| debug vs test | runtime failure selects `b-debug`; assertion/mock/fixture failure selects `b-test` | test mechanics diagnosed as product bug |
| browser vs test | browser/visual/e2e request selects `b-browser`; simulated DOM selects `b-test` | simulated test substituted for browser evidence |
| refactor vs redesign | named behavior-preserving transform selects `b-refactor`; unclear cleanup/redesign selects `b-plan` | broad redesign treated as mechanical refactor |
| summary vs review | explicit staged-change PR copy selects `b-summary`; changed-code critique selects `b-review` | review performed when only PR copy was requested |

A failure must name the concrete prompt/skill defect and add or update a
narrow static fixture before changing a skill prompt. Do not expand unrelated
prompts or claim a general routing result from one model/runtime observation.
